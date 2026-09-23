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
                .onChange(of: scenePhase) { phase in
                    TaskDone.appActive = phase == .active
                    if phase == .active {
                        // 回前台时按未读实例数刷新角标
                        TaskDone.syncBadge()
                    }
                }
                .task { TaskDone.requestAuthorization() }
        }
    }
}
