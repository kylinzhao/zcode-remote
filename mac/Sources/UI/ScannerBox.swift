import SwiftUI
import AppKit
import AVFoundation

/// 相机权限：已授权返回 true；未决定则弹系统询问；被拒返回 false（语义同 iOS ScanSheet）。
/// 全仓唯一定义，Quota 模块的扫码导入共用（CONTRACT ①：单一编译目标下重名定义会
/// invalid redeclaration，且只在合编时爆）。
func requestCameraAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
    default: return false
    }
}

/// 相机取景扫码封装（iOS DataScannerViewController 的 mac 对应物，签名由 CONTRACT ① 固定）：
/// granted 变 true 后开始取流；仅识别二维码；识别到 payload 回调一次，
/// 同一 payload 不重复回调、换了新码仍会回调（重新绑定场景需要继续扫）。
/// 本 UI 模块的添加/换链接页走「粘贴 + 二维码截图解码」（mac 按无相机扫码设计），
/// 此封装仅为履行共享契约、供 Quota 扫码导入复用，UI 自身不使用。
struct ScannerBox: NSViewRepresentable {
    @Binding var granted: Bool
    let onPayload: (String) -> Void

    init(granted: Binding<Bool>, onPayload: @escaping (String) -> Void) {
        self._granted = granted
        self.onPayload = onPayload
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.previewLayer.session = context.coordinator.session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        context.coordinator.onPayload = onPayload
        // granted 驱动取流：true 开始、false 停止（权限被收回时及时释放相机）
        context.coordinator.setRunning(granted)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: Coordinator) {
        // 停流并断开 output → coordinator 的引用，防泄漏
        coordinator.shutdown()
    }

    /// 取景视图：把 AVCaptureVideoPreviewLayer 直接作为 backing layer。
    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("ScannerBox.PreviewView 不经 IB 初始化")
        }

        override func makeBackingLayer() -> CALayer {
            previewLayer
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onPayload: (String) -> Void
        let session = AVCaptureSession()
        private let metadataOutput = AVCaptureMetadataOutput()
        // startRunning 是阻塞调用，Apple 要求在固定的后台串行队列上驱动会话
        private let sessionQueue = DispatchQueue(label: "dev.zcode.remote.mac.scannerbox")
        private var configured = false
        private var shuttingDown = false
        // 回调固定在主队列（setDelegate 指定），去重状态也只在主队列读写
        private var lastPayload: String?

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func setRunning(_ running: Bool) {
            sessionQueue.async { [self] in
                guard !shuttingDown else { return }
                if running {
                    configureIfNeeded()
                    // 无摄像头（台式机未接）时保持空会话，不 startRunning（会刷错误日志）；
                    // 兜底 UI 是调用方的事
                    if !session.inputs.isEmpty {
                        session.startRunning()
                    }
                } else if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        func shutdown() {
            sessionQueue.async { [self] in
                shuttingDown = true
                if session.isRunning {
                    session.stopRunning()
                }
                metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
            }
        }

        /// 会话装配只在串行队列上做一次。
        private func configureIfNeeded() {
            guard !configured else { return }
            configured = true
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    // metadataObjectTypes 必须在 addOutput 之后设置；
                    // macOS 的方法名是 setMetadataObjectsDelegate（iOS 侧同名选择子）
                    metadataOutput.metadataObjectTypes = [.qr]
                    metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                }
            }
            session.commitConfiguration()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for case let obj in metadataObjects {
                guard let qr = obj as? AVMetadataMachineReadableCodeObject,
                      qr.type == .qr,
                      let payload = qr.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty, payload != lastPayload else { continue }
                // 同一个码反复识别只回调一次；换了码（先扫错、再扫对）仍会回调
                lastPayload = payload
                onPayload(payload)
            }
        }
    }
}
