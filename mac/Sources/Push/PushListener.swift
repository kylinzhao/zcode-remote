import Foundation
import Combine

/// 通道二（ntfy 推送）订阅：为每个配置了 ntfyTopic 的实例维持一条 ntfy.sh /json 长连接，
/// 收到消息点亮红点并发系统通知。窗口关掉、屏幕锁定也能收到——补上注入脚本检测（通道一）
/// 只在远程页处于窗口层级时有效的缺口。mac 无需 Android 的前台服务保活：关窗口不退出
/// 进程，进程常驻即监听；退出 App（⌘Q）才停。
@MainActor
final class PushListener {
    static let shared = PushListener()

    /// topic → 该 topic 的订阅协程（ cancelling 即断开重连循环）。
    private var watchers: [String: Task<Void, Never>] = [:]
    private var cancellable: AnyCancellable?

    private init() {}

    /// App 启动时调用一次；此后跟随实例表变化自动增删连接（幂等，重复调用无害）。
    func start() {
        guard cancellable == nil else { return }
        sync()
        cancellable = InstanceStore.shared.$instances
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
    }

    /// 按当前实例表对齐订阅：新增 topic 起连接，删掉的不留（Android TaskListenService.syncWatchers 同构）。
    /// markDone 等红点变更也会触发这里，但 topic 集合未变时是空操作。
    private func sync() {
        let wanted = Dictionary(
            InstanceStore.shared.instances.compactMap { inst in inst.ntfyTopic.map { ($0, inst.id) } },
            uniquingKeysWith: { first, _ in first }   // 两个实例误填同一 topic：只跟一个，避免双份通知
        )
        // 先 filter 快照再删：直接在 keys 视图上边遍历边 remove 会漏元素（Android 版 toList 同理）
        for topic in watchers.keys.filter({ wanted[$0] == nil }) {
            watchers.removeValue(forKey: topic)?.cancel()
        }
        for (topic, instanceID) in wanted where watchers[topic] == nil {
            watchers[topic] = Task.detached { await Self.watch(topic: topic, instanceID: instanceID) }
        }
    }

    /// 单 topic 长连接：断线按退避重连（2s 起指数退避、封顶 60s），语义对齐 Android 版 watch()。
    /// nonisolated：本类型 @MainActor，不标注的话流处理会被隔离到主 actor，行回调全排队走主线程。
    private nonisolated static func watch(topic: String, instanceID: UUID) async {
        var backoffNs: UInt64 = 2_000_000_000
        while !Task.isCancelled {
            var comps = URLComponents(string: "https://ntfy.sh/\(topic)/json")
            // since=连接时刻：重连不回放历史消息，睡醒后不补发通知风暴（Android 同策略）
            comps?.queryItems = [URLQueryItem(name: "since", value: String(Int(Date().timeIntervalSince1970)))]
            guard let url = comps?.url else { return }
            var req = URLRequest(url: url)
            // ntfy 心跳约 45s 一次；2 分钟无数据视为连接已死，主动重连（对齐 Android readTimeout）
            req.timeoutInterval = 120
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                for try await line in bytes.lines {
                    if let event = Ntfy.parse(line: String(line)), event.event == "message" {
                        await TaskDone.handlePush(instanceID: instanceID, title: event.title, body: event.message)
                        backoffNs = 2_000_000_000   // 收到过数据说明链路健康，退避归零
                    }
                }
                // 流正常结束（服务端关闭）也走重连
            } catch {
                // 断线/超时/单次失败不影响监听：退避后重连
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: backoffNs)
            backoffNs = min(backoffNs * 2, 60_000_000_000)
        }
    }
}
