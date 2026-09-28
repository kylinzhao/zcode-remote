import SwiftUI
import VisionKit

/// 编辑实例内的扫码重新绑定：只把扫到的远程链接回传，替换网址与保存仍由编辑页完成。
struct RebindScanSheet: View {
    let onURL: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraGranted = false
    @State private var scannerAvailable = DataScannerViewController.isAvailable
    @State private var invalidTip: String?

    var body: some View {
        NavigationStack {
            Group {
                if scannerAvailable {
                    ScannerBox(granted: $cameraGranted) { payload in
                        handlePayload(payload)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("此设备无法使用相机扫码，请关闭后在网址栏手动粘贴新链接")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let invalidTip {
                    Text(invalidTip)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 28)
                }
            }
            .background { Color.black.ignoresSafeArea() }
            .navigationTitle("扫码重新绑定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if scannerAvailable {
                    cameraGranted = await requestCameraAccess()
                }
            }
        }
    }

    private func handlePayload(_ raw: String) {
        guard let candidate = Urls.extractRemoteURL(raw),
              let url = Urls.sanitize(candidate) else {
            invalidTip = "二维码里没有 ZCode 远程链接，请对准电脑端「远程访问」二维码"
            return
        }
        dismiss()
        onURL(url)
    }
}
