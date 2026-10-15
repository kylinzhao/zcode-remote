import SwiftUI

@main
struct ZCodeRemoteApp: App {
    /// CI/调试入口：`-ZCODE_AUTOPEN_URL <url>` 启动参数可自动添加并打开一个实例。
    @State private var autoOpenURL: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-ZCODE_AUTOPEN_URL"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(autoOpenURL: autoOpenURL)
                // iOS 用的单参 onChange 在 macOS 14 已弃用，这里换等价双参版（行为一致）
                .onChange(of: scenePhase) { _, phase in
                    TaskDone.appActive = phase == .active
                    if phase == .active {
                        // 回前台时按未读实例数刷新角标
                        TaskDone.syncBadge()
                    }
                }
                .task {
                    TaskDone.requestAuthorization()
                    // 通道二（ntfy 推送）：进程常驻即订阅，此后跟随实例表自动增删连接
                    PushListener.shared.start()
                }
        }
    }
}
