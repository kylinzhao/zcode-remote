import SwiftUI

/// 二维码截图识别的公共支持：CoreImage 解码 + 拖入/粘贴/选图的识别区组件。
/// 添加实例与「换链接」两处共用；Quota 模块不复用（其扫码走 ScannerBox，见 CONTRACT ①）。
import AppKit
import CoreImage
import UniformTypeIdentifiers

/// 二维码截图解码：CIDetector(.qr)。mac 无相机扫码，
/// 「扫电脑端二维码」的平台替代是识别用户粘贴/拖入的二维码截图。
enum QRImage {
    /// 返回二维码载荷原文（通常是远程链接，也可能是内嵌链接的文本）；未识别到返回 nil。
    /// 与 iOS 相机扫码拿到的 payload 同一形态，由调用方走 Urls.extractRemoteURL 判定。
    static func payload(in image: NSImage) -> String? {
        // 走 TIFF 表示取原始像素：cgImage(forProposedRect:) 按点尺寸栅格化，
        // Retina 截图会被降采样，小尺寸二维码容易识别不出来
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        // macOS SDK 导出的常量名是 CIDetectorTypeQRCode（iOS 头里才叫 CIDetectorTypeQR）
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        for case let qr as CIQRCodeFeature in detector?.features(in: CIImage(cgImage: cg)) ?? [] {
            if let s = qr.messageString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

/// 二维码截图识别区：拖入 / ⌘V 粘贴 / 文件选择 / 读剪贴板，四种入口共用同一解码。
/// 解码失败只写 invalidTip（由调用方统一呈现），成功才回调 onPayload。
struct QRDropZone: View {
    @Binding var invalidTip: String?
    let onPayload: (String) -> Void

    init(invalidTip: Binding<String?>, onPayload: @escaping (String) -> Void) {
        self._invalidTip = invalidTip
        self.onPayload = onPayload
    }

    @State private var isTargeted = false
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(isTargeted ? "松开识别二维码" : "拖入二维码截图，或 ⌘V 粘贴截图")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("选择图片…") { showingPicker = true }
                Button("粘贴图片") { pasteFromPasteboard() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            // 虚线框是拖放目标的惯例视觉；命中时高亮提示可松手
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
        )
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
            accept(providers)
        }
        // ⌘V 粘贴截图（焦点在文本框时文本粘贴优先进文本框，图片粘贴落到这里；
        // 确定性入口是「粘贴图片」按钮，直接读剪贴板）
        .onPasteCommand(of: [.image]) { providers in
            _ = accept(providers)
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            if let image = NSImage(contentsOf: url) {
                decode(image)
            } else {
                invalidTip = "无法读取所选图片"
            }
        }
    }

    /// 优先按图片数据取（截图/浏览器拖出），退回 fileURL（Finder 拖文件）。
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
                ?? providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data, let image = NSImage(data: data) {
                        decode(image)
                    } else {
                        loadFromFileURL(provider)
                    }
                }
            }
        } else {
            loadFromFileURL(provider)
        }
        return true
    }

    /// fileURL 约定的 data 是 URL 字节而非图片内容，须落盘读取。
    private func loadFromFileURL(_ provider: NSItemProvider) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            DispatchQueue.main.async {
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      let image = NSImage(contentsOf: url) else {
                    invalidTip = "无法读取拖入的图片"
                    return
                }
                decode(image)
            }
        }
    }

    private func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        if let image = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first {
            decode(image)
        } else if let url = (pb.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
                  let image = NSImage(contentsOf: url) {
            decode(image)
        } else {
            invalidTip = "剪贴板里没有图片"
        }
    }

    private func decode(_ image: NSImage) {
        if let payload = QRImage.payload(in: image) {
            onPayload(payload)
        } else {
            invalidTip = "图片里没有识别到二维码"
        }
    }
}
