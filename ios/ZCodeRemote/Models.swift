import Foundation

/// 电脑实例模型（与 Android 版数据结构对齐）。
struct Instance: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var keepScreenOn: Bool
    /// iPad 默认以桌面形态加载；iPhone 可在编辑页打开。
    var desktopMode: Bool
    var createdAt: Date
    var lastOpenedAt: Date?
    /// 任务结束且用户不在场的未读提醒；nil = 无。Optional 保证旧 JSON 文件可解码。
    var unreadDone: Bool?
}

/// 实例本地存储：Application Support 下 JSON 文件。
/// 仅在主线程读写（所有调用来自 UI 层）；@Published 驱动界面刷新。
final class InstanceStore: ObservableObject {
    static let shared = InstanceStore()

    @Published private(set) var instances: [Instance] = []

    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZCodeRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("instances.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        instances = (try? JSONDecoder().decode([Instance].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(instances) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func instance(_ id: UUID) -> Instance? {
        instances.first { $0.id == id }
    }

    func instance(withURL url: String) -> Instance? {
        instances.first { $0.url == url }
    }

    /// 新增或更新；返回是否为新增。
    @discardableResult
    func upsert(_ instance: Instance) -> Bool {
        if let idx = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[idx] = instance
            persist()
            return false
        }
        instances.append(instance)
        persist()
        return true
    }

    func markOpened(_ id: UUID) {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[idx].lastOpenedAt = Date()
        persist()
    }

    /// 页面侧检测到任务结束（用户不在场）→ 点亮该实例红点。
    func markDone(_ id: UUID) {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        if instances[idx].unreadDone != true {
            instances[idx].unreadDone = true
            persist()
        }
    }

    /// 用户打开该实例 → 清除红点。
    func clearDone(_ id: UUID) {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        if instances[idx].unreadDone != nil {
            instances[idx].unreadDone = nil
            persist()
        }
    }

    var unreadDoneCount: Int { instances.count { $0.unreadDone == true } }

    func remove(_ id: UUID) {
        instances.removeAll { $0.id == id }
        persist()
    }
}

enum Urls {
    /// 与 Android 版一致：去空白/控制字符与首尾杂字符，仅接受 https。
    static func sanitize(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        let junk = Set(" \"'<>),.;。」』）】]")
        while let f = s.first, junk.contains(f) { s.removeFirst() }
        while let l = s.last, junk.contains(l) { s.removeLast() }
        guard s.lowercased().hasPrefix("https://"), let u = URL(string: s), u.host()?.isEmpty == false else {
            return nil
        }
        return s
    }

    /// 从远程链接 name 参数建议实例名（去 .local 后缀）。
    static func suggestName(_ urlString: String) -> String? {
        guard let u = URL(string: urlString),
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let name = comps.queryItems?.first(where: { $0.name == "name" })?.value
        else { return nil }
        let trimmed = name
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
    }

    /// 从二维码载荷提取远程链接（纯 URL 或文本内嵌 URL）。
    static func extractRemoteURL(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("https://") || t.lowercased().hasPrefix("http://") { return t }
        return t.range(of: "https://\\S+", options: .regularExpression).map { String(t[$0]) }
    }

    /// 桌面形态 UA（macOS Safari），iPad 或开启桌面模式时使用。
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
}

extension Array where Element == Instance {
    /// 恰好一个元素时返回它，否则 nil（`single` 的非崩溃版）。
    var only: Element? { count == 1 ? first : nil }

    /// 最近打开过的实例（冷启动恢复用）；都没有打开记录时返回 nil。
    var lastOpened: Element? {
        compactMap { instance -> (Instance, Date)? in
            instance.lastOpenedAt.map { (instance, $0) }
        }
        .max { $0.1 < $1.1 }?.0
    }
}

extension Date {
    /// 中文相对时间："3分钟前"；nil → "未打开过"。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "未打开过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
