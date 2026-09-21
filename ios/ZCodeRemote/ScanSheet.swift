import SwiftUI
import VisionKit
import AVFoundation
import Vision

/// 扫码添加：对准电脑端 ZCode「远程访问」二维码；无法使用相机时提供粘贴兜底。
struct ScanSheet: View {
    /// 扫到/保存后回调实例 id，用于导航打开。
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InstanceStore.shared
    @State private var pasteText = ""
    @State private var invalidTip: String?
    @State private var cameraGranted = false
    @State private var scannerAvailable = DataScannerViewController.isAvailable
    @State private var settled = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scannerAvailable {
                    ScannerBox(granted: $cameraGranted) { payload in
                        handlePayload(payload)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("此设备无法使用相机扫码（模拟器或不支持的数据扫描器），请手动粘贴链接")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                pasteSection
            }
            .padding(.bottom, 12)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("扫码添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if scannerAvailable {
                    cameraGranted = await requestCamera()
                }
            }
        }
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动粘贴链接").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                TextField("https://zcode.z.ai/remote/…", text: $pasteText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("添加") { handlePayload(pasteText) }
                    .buttonStyle(.borderedProminent)
            }
            if let invalidTip {
                Text(invalidTip).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
    }

    private func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func handlePayload(_ raw: String) {
        guard !settled else { return }
        guard let candidate = Urls.extractRemoteURL(raw),
              let url = Urls.sanitize(candidate) else {
            invalidTip = raw.isEmpty ? nil : "二维码/文本里没有 ZCode 远程链接：\(raw.prefix(24))"
            return
        }
        settled = true
        let instance: Instance
        if let existing = store.instance(withURL: url) {
            instance = existing
        } else {
            instance = Instance(
                id: UUID(),
                name: Urls.suggestName(url) ?? "ZCode 实例",
                url: url,
                keepScreenOn: false,
                desktopMode: UIDevice.current.userInterfaceIdiom == .pad,
                createdAt: Date(),
                lastOpenedAt: nil)
            store.upsert(instance)
        }
        store.markOpened(instance.id)
        dismiss()
        onSaved(instance.id)
    }
}

/// DataScannerViewController 封装：仅识别二维码。
private struct ScannerBox: UIViewControllerRepresentable {
    @Binding var granted: Bool
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: false)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if granted {
            if !uiViewController.isScanning {
                try? uiViewController.startScanning()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void
        private var fired = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !payload.isEmpty {
                    fired = true
                    onPayload(payload)
                    return
                }
            }
        }
    }
}
