import Foundation

/// 待查额度的 LLM 账号（与 Android 版 LlmAccount 对齐）。
/// coding-plan API key 优先，JWT 兜底；凭据只存应用沙盒。
struct LlmAccount: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var apiKey: String?
    var jwt: String?
    var teamOrg: String?
    var teamProj: String?
    var overview: QuotaOverview?
    var lastRefreshAt: Date?
    var lastError: String?
}

/// 一个额度条目（如「每 5 小时额度」或 billing 通道按模型明细）。
struct QuotaItemView: Codable, Equatable {
    var name: String
    var window: String?
    var total: Double?
    var used: Double?
    var remaining: Double?
    var percentUsed: Double?
    var resetAt: String?
}

/// 一个套餐槽位（billing 通道一个账号可能有多个 active 套餐）。
struct QuotaPlanView: Codable, Equatable {
    var tier: String?
    var name: String?
    var expire: String?
    var items: [QuotaItemView]

    var total: Double? {
        let vals = items.compactMap(\.total)
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    var used: Double? {
        let vals = items.compactMap(\.used)
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    var percentUsed: Double? {
        guard let t = total, let u = used, t > 0 else { return nil }
        return min(max(u / t * 100, 0), 100)
    }
}

/// 一次刷新得到的账号额度全貌。
struct QuotaOverview: Codable, Equatable {
    var tier: String?
    var expire: String?
    var plans: [QuotaPlanView]
    var source: String
    var refreshedAt: Date
    var resetCards: String?

    /// 卡片头部展示用的主槽位：套餐等级最高者优先。
    var primaryPlan: QuotaPlanView? {
        plans.max { QuotaClient.tierRank($0.tier) < QuotaClient.tierRank($1.tier) }
    }
}

/// 账号本地存储：Application Support/ZCodeRemote/accounts.json（与 InstanceStore 同一套路数）。
final class QuotaAccountStore: ObservableObject {
    static let shared = QuotaAccountStore()

    @Published private(set) var accounts: [LlmAccount] = []

    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZCodeRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("accounts.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        accounts = (try? JSONDecoder().decode([LlmAccount].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func account(_ id: UUID) -> LlmAccount? {
        accounts.first { $0.id == id }
    }

    @discardableResult
    func upsert(_ account: LlmAccount) -> Bool {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
            persist()
            return false
        }
        accounts.append(account)
        persist()
        return true
    }

    /// 刷新完成回写：只在仍有该账号时落盘（可能已被删除）。
    func apply(_ updated: LlmAccount) {
        guard accounts.contains(where: { $0.id == updated.id }) else { return }
        upsert(updated)
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        persist()
    }

    /// 导入合并（同名账号覆盖凭据），整体落盘。返回 (新增数, 更新数)。
    @discardableResult
    func mergeImport(_ incoming: [LlmAccount]) -> (Int, Int) {
        var list = accounts
        let result = QuotaImport.merge(into: &list, incoming)
        accounts = list
        persist()
        return result
    }
}

/// 「额度账号」导入载荷解析，与 Android 版 QuotaImport 语义一致：
/// `{"v":1,"type":"zcode-remote-accounts","accounts":[{"n":"名","k":"apikey","jwt":"…","team":{"org":"…","proj":"…"}}]}`，
/// 兼容裸数组与单对象。同名账号视为同一账号，凭据覆盖。
enum QuotaImport {
    static func parse(_ text: String) -> [LlmAccount]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        var raws: [[String: Any]] = []
        if let dict = root as? [String: Any] {
            if let arr = dict["accounts"] as? [[String: Any]] {
                raws = arr
            } else if let one = dict["accounts"] as? [String: Any] {
                raws = [one]
            } else if dict["k"] != nil || dict["key"] != nil || dict["jwt"] != nil {
                raws = [dict]
            }
        } else if let arr = root as? [[String: Any]] {
            raws = arr
        }
        var out: [LlmAccount] = []
        for (idx, raw) in raws.enumerated() {
            let team = raw["team"] as? [String: Any]
            let key = [raw["k"], raw["key"], raw["apiKey"], team?["key"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty }
            let jwt = [raw["jwt"], raw["token"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty }
            guard key != nil || jwt != nil else { continue }
            let name = ([raw["n"], raw["name"]].compactMap { $0 as? String }.first { !$0.isEmpty }) ?? "账号 \(idx + 1)"
            out.append(LlmAccount(
                id: UUID(),
                name: String(name.prefix(40)),
                apiKey: key,
                jwt: jwt,
                teamOrg: team?["org"] as? String,
                teamProj: team?["proj"] as? String,
                overview: nil, lastRefreshAt: nil, lastError: nil))
        }
        return out.isEmpty ? nil : out
    }

    /// 导入去重：同名账号覆盖凭据（保留 id 与上次额度）。返回 (新增数, 更新数)。
    static func merge(into existing: inout [LlmAccount], _ incoming: [LlmAccount]) -> (Int, Int) {
        var added = 0
        var updated = 0
        for a in incoming {
            if let idx = existing.firstIndex(where: { $0.name == a.name }) {
                if a.apiKey != nil { existing[idx].apiKey = a.apiKey }
                if a.jwt != nil { existing[idx].jwt = a.jwt }
                if a.teamOrg != nil { existing[idx].teamOrg = a.teamOrg }
                if a.teamProj != nil { existing[idx].teamProj = a.teamProj }
                updated += 1
            } else {
                existing.append(a)
                added += 1
            }
        }
        return (added, updated)
    }
}
