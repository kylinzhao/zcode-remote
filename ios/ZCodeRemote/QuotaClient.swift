import Foundation

/// 额度查询：与 Android 版 QuotaClient 同一套三通道策略 —
/// coding-plan key → open.bigmodel.cn monitor（团队 ?type=2 + 组织/项目头），失败换 api.z.ai；
/// subscription/list（套餐名/到期）与 customer-package-reset/list（重置卡）尽力而为；
/// JWT → zcode.z.ai billing/balance 兜底。
enum QuotaClient {

    private static let appVersion = "3.14.0"
    private static let noPlanWords = ["不存在coding plan", "没有资格"]

    static func tierRank(_ tier: String?) -> Int {
        guard let tier else { return -1 }
        let t = tier.lowercased()
        if t.contains("max") { return 5 }
        if t.contains("pro") { return 4 }
        if t.contains("lite") { return 3 }
        if t.contains("start") { return 2 }
        if t.contains("trial") || tier == "体验" { return 1 }
        return 0
    }

    /// 刷新一个账号；失败抛出 QuotaError（message 已面向用户）。
    static func refresh(_ account: LlmAccount) async throws -> QuotaOverview {
        var errors: [String] = []
        let keys = [account.apiKey].compactMap { $0 }
        for key in keys {
            do {
                return try await monitor(account, key: key)
            } catch let e as QuotaError {
                errors.append(e.message)
            } catch {
                errors.append("网络错误：\(error.localizedDescription)")
            }
        }
        if let jwt = account.jwt, !jwt.isEmpty {
            do {
                return try await billing(jwt)
            } catch let e as QuotaError {
                errors.append(e.message)
            } catch {
                errors.append("网络错误：\(error.localizedDescription)")
            }
        }
        let joined = errors.removingDuplicates().joined(separator: "；")
        throw QuotaError(joined.isEmpty ? "没有可用的账号凭据" : joined)
    }

    // MARK: - 通道一：monitor

    private static func monitor(_ account: LlmAccount, key: String) async throws -> QuotaOverview {
        var teamHeaders: [String: String] = [:]
        var isTeam = false
        if let org = account.teamOrg, !org.isEmpty {
            isTeam = true
            teamHeaders["bigmodel-organization"] = org
            if let proj = account.teamProj, !proj.isEmpty {
                teamHeaders["bigmodel-project"] = proj
            }
        }
        var lastError: String?
        var noPlan = false
        for base in ["https://open.bigmodel.cn", "https://api.z.ai"] {
            do {
                var url = base + "/api/monitor/usage/quota/limit"
                if isTeam { url += "?type=2" }
                let resp = try await getJSON(url, token: key, headers: teamHeaders)
                if businessOK(resp) {
                    let sub = try? await getJSON(base + "/api/biz/subscription/list", token: key, headers: teamHeaders)
                    var ov = parseMonitor(resp, sub: sub)
                    let resetPath = "/api/biz/customer-package-reset/list?targetType=\(isTeam ? "TEAM" : "PERSONAL")"
                    if let reset = try? await getJSON(base + resetPath, token: key, headers: teamHeaders) {
                        ov.resetCards = parseResetCards(reset)
                    }
                    return ov
                }
                let msg = resp["msg"] as? String ?? (resp["message"] as? String) ?? ""
                if noPlanWords.contains(where: msg.contains) {
                    noPlan = true
                } else if lastError == nil {
                    let code = resp["code"] as? Int ?? 0
                    lastError = "bigmodel 业务错误 \(code): \(msg.prefix(60))"
                }
            } catch let e as QuotaError {
                if e.isAuth { throw e }
                if lastError == nil { lastError = e.message }
            } catch {
                if lastError == nil { lastError = "网络错误：\(error.localizedDescription)" }
            }
        }
        throw QuotaError(noPlan ? "这把 key 下没有 coding plan" : (lastError ?? "查询失败"))
    }

    // MARK: - 通道二：billing

    private static func billing(_ jwt: String) async throws -> QuotaOverview {
        let resp = try await getJSON(
            "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=\(appVersion)",
            token: jwt,
            headers: [
                "User-Agent": "ZCode/\(appVersion)",
                "HTTP-Referer": "https://zcode.z.ai",
                "X-Title": "Z Code@electron",
                "X-ZCode-App-Version": appVersion,
                "X-Release-Channel": "stable",
                "X-Client-Language": "zh-CN",
            ])
        guard businessOK(resp) else {
            throw QuotaError("billing 接口返回 code=\(resp["code"] as? Int ?? -1)")
        }
        return parseBalance(resp)
    }

    // MARK: - HTTP

    struct QuotaError: Error {
        let message: String
        var isAuth = false
        init(_ message: String, isAuth: Bool = false) {
            self.message = message
            self.isAuth = isAuth
        }
    }

    private static func businessOK(_ o: [String: Any]) -> Bool {
        let codeOk: Bool
        if o["code"] == nil {
            codeOk = true
        } else {
            let code = o["code"] as? Int ?? -1
            codeOk = code == 200 || code == 0
        }
        let success = o["success"] as? Bool ?? true
        return codeOk && success
    }

    private static func getJSON(_ url: String, token: String, headers: [String: String]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw QuotaError("URL 无效") }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("ZCode/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response, error): (Data, URLResponse?, Error?) = await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, r, e in
                cont.resume(returning: (d ?? Data(), r, e))
            }.resume()
        }
        if let error {
            throw QuotaError("网络错误：\(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {
            throw QuotaError("请求过于频繁（429），稍后再试")
        }
        if code == 401 || code == 403 {
            throw QuotaError("凭证无效（HTTP \(code)）", isAuth: true)
        }
        guard (200..<300).contains(code) else {
            let msg = errorMessage(data)
            throw QuotaError("HTTP \(code) \(msg)")
        }
        guard !data.isEmpty else { throw QuotaError("响应为空") }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        if let dict = parsed as? [String: Any] { return dict }
        if let arr = parsed as? [Any] { return ["data": arr] }
        throw QuotaError("响应格式异常")
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["message", "msg", "error"] {
            if let s = o[key] as? String, !s.isEmpty { return String(s.prefix(80)) }
        }
        return ""
    }

    // MARK: - 解析：monitor/limit + subscription

    private static func parseMonitor(_ limit: [String: Any], sub: [String: Any]?) -> QuotaOverview {
        let data = limit["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []
        var items: [QuotaItemView] = []
        for l in limits {
            let window = windowLabel(unit: l["unit"] as? Int ?? -1, number: l["number"] as? Int ?? 0)
            let total = l["usage"] as? Double
            let used = l["currentValue"] as? Double
            let remaining = l["remaining"] as? Double
            let percent: Double?
            if let t = total, let u = used, t > 0 {
                percent = min(max(u / t * 100, 0), 100)
            } else if let p = l["percentage"] as? Double {
                percent = min(max(p, 0), 100)
            } else if let p = l["percentage"] as? Int {
                percent = min(max(Double(p), 0), 100)
            } else {
                percent = nil
            }
            let resetAt: String?
            if let ms = l["nextResetTime"] as? Int64, ms > 0 {
                resetAt = fmtTime(ms, "MM-dd HH:mm")
            } else if let ms = l["nextResetTime"] as? Int, ms > 0 {
                resetAt = fmtTime(Int64(ms), "MM-dd HH:mm")
            } else {
                resetAt = nil
            }
            items.append(QuotaItemView(
                name: "\(window ?? "每周期")额度", window: window,
                total: total, used: used, remaining: remaining,
                percentUsed: percent, resetAt: resetAt))
        }

        var tier = (data["level"] as? String).flatMap(nonEmpty).map(tierFromLevel)
        var expire: String?
        if let sub, businessOK(sub), let arr = sub["data"] as? [[String: Any]] {
            let current = arr.first { ($0["status"] as? String) == "VALID" && (($0["inCurrentPeriod"] as? Bool) ?? true) } ?? arr.first
            if let current {
                if let pn = (current["productName"] as? String).flatMap(nonEmpty) {
                    tier = tierFromLevel(pn)
                }
                expire = extractExpire(current)
            }
        }
        let plans = (tier != nil || !items.isEmpty)
            ? [QuotaPlanView(tier: tier, name: nil, expire: expire, items: items)]
            : []
        return QuotaOverview(tier: tier, expire: expire, plans: plans, source: "monitor",
                             refreshedAt: Date(), resetCards: nil)
    }

    // MARK: - 解析：billing/balance

    private static func parseBalance(_ resp: [String: Any]) -> QuotaOverview {
        let balance = unwrapData(resp)
        struct Slot {
            var pid: String
            var tier: String?
            var name: String
            var expire: String?
            var items: [QuotaItemView] = []
        }
        var slots: [Slot] = []
        for p in balance["plans"] as? [[String: Any]] ?? [] {
            guard (p["status"] as? String)?.lowercased() == "active" else { continue }
            let pid = p["plan_id"] as? String ?? ""
            let pname = (p["name"] as? String).flatMap(nonEmpty)
            slots.append(Slot(pid: pid, tier: tierFromPlan(pid: pid, name: pname).0,
                              name: pname ?? pid, expire: extractExpire(p)))
        }
        let balances = balance["balances"] as? [[String: Any]] ?? []
        let anyPid = balances.contains { b in
            ["plan_id", "planId", "entitlement_id"].contains { (b[$0] as? String)?.isEmpty == false }
        }
        var loose: [QuotaItemView] = []
        for b in balances {
            let total = b["total_units"] as? Double ?? (b["total_units"] as? Int).map(Double.init)
            let used = b["used_units"] as? Double ?? (b["used_units"] as? Int).map(Double.init)
            let remaining = b["remaining_units"] as? Double ?? (b["remaining_units"] as? Int).map(Double.init)
                ?? b["available_units"] as? Double ?? (b["available_units"] as? Int).map(Double.init)
            let percent: Double?
            if let t = total, let u = used, t > 0 { percent = min(max(u / t * 100, 0), 100) } else { percent = nil }
            let name = ["show_name", "name", "entitlement_id", "plan_id"]
                .compactMap { b[$0] as? String }.first { !$0.isEmpty } ?? "Unknown"
            let resetAt = ["period_end", "expires_at"].compactMap { b[$0] }.first.flatMap(extractExpireValue)
            let item = QuotaItemView(name: name, window: nil, total: total, used: used,
                                     remaining: remaining, percentUsed: percent, resetAt: resetAt)
            let bpid = ["plan_id", "planId", "entitlement_id"]
                .compactMap { b[$0] as? String }.first { !$0.isEmpty } ?? ""
            if !bpid.isEmpty, let idx = slots.firstIndex(where: { $0.pid == bpid }) {
                slots[idx].items.append(item)
                if slots[idx].expire == nil { slots[idx].expire = resetAt }
            } else if slots.count == 1, !anyPid {
                slots[0].items.append(item)
                if slots[0].expire == nil { slots[0].expire = resetAt }
            } else {
                loose.append(item)
            }
        }
        if !loose.isEmpty {
            slots.append(Slot(pid: "", tier: nil, name: "其他额度", expire: nil, items: loose))
        }
        slots = slots.map { s in
            var s = s
            if s.items.isEmpty {
                s.items = [QuotaItemView(name: s.name, window: nil, total: nil, used: nil,
                                         remaining: nil, percentUsed: nil, resetAt: s.expire)]
            }
            return s
        }
        let primary = slots.max { tierRank($0.tier) < tierRank($1.tier) }
        return QuotaOverview(
            tier: primary?.tier,
            expire: primary?.expire,
            plans: slots.map { QuotaPlanView(tier: $0.tier, name: $0.name, expire: $0.expire, items: $0.items) },
            source: "billing", refreshedAt: Date(), resetCards: nil)
    }

    // MARK: - 重置卡

    private static func parseResetCards(_ resp: [String: Any]) -> String? {
        guard let data = resp["data"] as? [String: Any] else { return nil }
        func group(_ name: String) -> String? {
            guard let arr = data[name] as? [[String: Any]] else { return nil }
            var available = 0
            var nextExpire: String?
            for r in arr {
                guard (r["available"] as? Bool) == true else { continue }
                available += 1
                if let e = r["expireTime"] as? String, !e.isEmpty {
                    if nextExpire == nil || e < nextExpire! { nextExpire = e }
                }
            }
            guard available > 0 else { return nil }
            return "\(available)/\(arr.count) 张"
        }
        var parts: [String] = []
        if let g = group("fiveHourResets") { parts.append("5h卡 \(g)") }
        if let g = group("weekResets") { parts.append("周卡 \(g)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 工具

    private static func unwrapData(_ o: [String: Any]) -> [String: Any] {
        var cur = o
        for _ in 0..<4 {
            guard let d = cur["data"] as? [String: Any] else { break }
            cur = d
        }
        return cur
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func windowLabel(unit: Int, number: Int) -> String? {
        switch unit {
        case 3: return "每 \(number > 0 ? number : 5) 小时"
        case 4: return "每天"
        case 5: return "每月"
        case 6: return "每周"
        default: return nil
        }
    }

    private static func tierFromLevel(_ level: String) -> String {
        let l = level.lowercased()
        if l.contains("max") { return "Max" }
        if l.contains("pro") { return "Pro" }
        if l.contains("lite") { return "Lite" }
        return level
    }

    private static func tierFromPlan(pid: String, name: String?) -> (String?, String) {
        let hay = (pid + " " + (name ?? "")).lowercased()
        if hay.contains("max") { return ("Max", "max") }
        if hay.contains("pro") { return ("Pro", "pro") }
        if hay.contains("lite") { return ("Lite", "lite") }
        if hay.contains("start") { return ("Start Plan", "start") }
        if ["trial", "taste", "experience", "gift", "weekend", "promo", "体验"].contains(where: hay.contains) {
            return ("体验", "trial")
        }
        return (name.flatMap(nonEmpty), "other")
    }

    private static let expireKeys = [
        "nextRenewTime", "expireTime", "expire_time", "endTime", "end_time", "expireAt",
        "expiredTime", "validEndTime", "expires_at", "expiresAt", "expired_at", "period_end",
    ]

    private static func extractExpire(_ o: [String: Any]) -> String? {
        for k in expireKeys {
            if let v = o[k], let s = extractExpireValue(v) { return s }
        }
        return nil
    }

    private static func extractExpireValue(_ v: Any) -> String? {
        if let n = v as? Int64 {
            return fmtTime(n > 1_000_000_000_000 ? n : n * 1000, "yyyy-MM-dd HH:mm")
        }
        if let n = v as? Int {
            return fmtTime(n > 1_000_000_000_000 ? n : n * 1000, "yyyy-MM-dd HH:mm")
        }
        if let n = v as? Double {
            return fmtTime(n > 1_000_000_000_000 ? n : n * 1000, "yyyy-MM-dd HH:mm")
        }
        guard let raw = v as? String else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let n = Int64(t) {
            return fmtTime(n > 1_000_000_000_000 ? n : n * 1000, "yyyy-MM-dd HH:mm")
        }
        if t.count >= 16, Array(t)[4] == "-", Array(t)[7] == "-" {
            return String(t.replacingOccurrences(of: "T", with: " ").prefix(16))
        }
        if t.count >= 10, Array(t)[4] == "-", Array(t)[7] == "-" {
            return String(t.prefix(10))
        }
        return t
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func fmtTime(_ millis: Int64, _ format: String) -> String {
        let f = format == "yyyy-MM-dd HH:mm" ? displayFormatter : DateFormatter()
        if format != "yyyy-MM-dd HH:mm" { f.dateFormat = format }
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func fmtReset(_ date: Date) -> String {
        resetFormatter.string(from: date)
    }
}

private extension Array where Element == String {
    var removingDuplicates: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
