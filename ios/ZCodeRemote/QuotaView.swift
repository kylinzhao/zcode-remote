import SwiftUI
import VisionKit

/// 账号额度页：多账号列表 + 额度进度条 + 扫码/手动导入 + 刷新（与 Android 版 QuotaActivity 对齐）。
struct QuotaView: View {
    @ObservedObject private var store = QuotaAccountStore.shared
    @State private var showingScan = false
    @State private var editing: LlmAccount?
    @State private var refreshing: Set<UUID> = []

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("账号额度")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingScan = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("扫码导入账号")
            }
            ToolbarItem(placement: .navigation) {
                Button { refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("全部刷新")
            }
        }
        .sheet(isPresented: $showingScan) {
            QuotaScanSheet()
        }
        .sheet(item: $editing) { account in
            AccountEditView(existing: account)
        }
    }

    private var accountList: some View {
        List {
            ForEach(store.accounts) { account in
                AccountCard(
                    account: account,
                    isRefreshing: refreshing.contains(account.id),
                    onRefresh: { refreshOne(account) },
                    onEdit: { editing = account }
                )
                .contextMenu {
                    Button { refreshOne(account) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    Button { editing = account } label: { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive) { store.remove(account.id) } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshAllAsync() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("还没有账号")
                .font(.title3.weight(.semibold))
            Text("在电脑端运行导出脚本生成账号二维码，点右上角「＋」扫码导入；或手动粘贴 API Key")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshAll() {
        Task { await refreshAllAsync() }
    }

    private func refreshAllAsync() async {
        let targets = store.accounts
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in targets {
                group.addTask { await refreshAccount(account) }
            }
        }
    }

    private func refreshOne(_ account: LlmAccount) {
        Task { await refreshAccount(account) }
    }

    @MainActor
    private func refreshAccount(_ account: LlmAccount) async {
        guard !refreshing.contains(account.id) else { return }
        refreshing.insert(account.id)
        defer { refreshing.remove(account.id) }
        var updated = account
        do {
            let overview = try await QuotaClient.refresh(account)
            updated.overview = overview
            updated.lastRefreshAt = Date()
            updated.lastError = nil
        } catch {
            updated.lastError = (error as? QuotaClient.QuotaError)?.message ?? error.localizedDescription
        }
        store.apply(updated)
    }
}

/// 单账号卡片：名称 + 套餐徽章 + 各窗口额度条 + 到期/重置卡/刷新时间 + 错误行。
private struct AccountCard: View {
    let account: LlmAccount
    let isRefreshing: Bool
    var onRefresh: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(account.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let tier = primary?.tier {
                    Text(tier)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.13), in: Capsule())
                }
                Spacer()
                Menu {
                    Button(action: onRefresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive) {
                        QuotaAccountStore.shared.remove(account.id)
                    } label: { Label("删除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }

            if items.isEmpty {
                Text(isRefreshing ? "正在查询额度…" : "暂无数据，点右上角刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.indices, id: \.self) { idx in
                bar(items[idx])
            }

            metaText.map { Text($0).font(.caption).foregroundStyle(.secondary) }
            account.lastError.map { Text($0).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    private var overview: QuotaOverview? { account.overview }
    private var primary: QuotaPlanView? { overview?.primaryPlan }
    private var items: [QuotaItemView] { primary?.items ?? [] }

    private var metaText: String? {
        var parts: [String] = []
        if let expire = primary?.expire { parts.append("到期 \(expire)") }
        if let cards = overview?.resetCards { parts.append(cards) }
        if let at = account.lastRefreshAt { parts.append("刷新于 \(QuotaClient.fmtReset(at))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func bar(_ q: QuotaItemView) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(q.window ?? q.name)
                Spacer()
                Text(detail(q))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let percent = q.percentUsed {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
                    .tint(percent >= 90 ? .red : (percent >= 75 ? .orange : .indigo))
            }
        }
        .padding(.top, 3)
    }

    private func detail(_ q: QuotaItemView) -> String {
        var parts: [String] = []
        switch (q.used, q.total) {
        case let (u?, t?): parts.append("\(fmtNum(u)) / \(fmtNum(t))")
        case let (u?, nil): parts.append("已用 \(fmtNum(u))")
        case let (nil, t?): parts.append("总量 \(fmtNum(t))")
        default: break
        }
        if let r = q.resetAt { parts.append("\(r) 重置") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func fmtNum(_ v: Double) -> String {
        if v >= 100_000_000 { return trimZero(v / 100_000_000) + "亿" }
        if v >= 10_000 { return trimZero(v / 10_000) + "万" }
        if v == v.rounded() {
            return NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
        }
        return String(format: "%.1f", v)
    }

    private func trimZero(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// 扫码导入账号：识别账号 JSON → 同名去重合并；模拟器/无相机时退化为粘贴框。
struct QuotaScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pasteText = ""
    @State private var invalidTip: String?
    @State private var cameraGranted = false
    @State private var scannerAvailable = DataScannerViewController.isAvailable
    @State private var resultTip: String?

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
                        Text("此设备无法使用相机扫码，请手动粘贴账号 JSON")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("手动粘贴账号 JSON").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("{\"accounts\":[…]}", text: $pasteText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                    Button("导入") { handlePayload(pasteText) }
                        .buttonStyle(.borderedProminent)
                    if let invalidTip {
                        Text(invalidTip).font(.footnote).foregroundStyle(.red)
                    }
                    if let resultTip {
                        Text(resultTip).font(.footnote).foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 12)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("扫码导入账号")
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
        guard let incoming = QuotaImport.parse(raw) else {
            invalidTip = raw.isEmpty ? nil : "二维码/文本里没有账号信息：\(raw.prefix(24))"
            resultTip = nil
            return
        }
        let (added, updated) = QuotaAccountStore.shared.mergeImport(incoming)
        invalidTip = nil
        resultTip = "已导入：新增 \(added) 个，更新 \(updated) 个"
        pasteText = ""
    }
}

/// 手动添加/编辑账号（扫码之外的兜底）。
struct AccountEditView: View {
    let existing: LlmAccount?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var apiKey = ""
    @State private var jwt = ""
    @State private var teamOrg = ""
    @State private var teamProj = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如：zhaofugui（Pro））", text: $name)
                } header: {
                    Text("名称")
                }
                Section {
                    SecureField("coding-plan key，长期有效", text: $apiKey)
                } header: {
                    Text("coding-plan API Key")
                } footer: {
                    Text("推荐用电脑端导出脚本 + 扫码导入；手动填 key 可在电脑端 ~/.zcode/v2/credentials.json 里找（名称含 coding-plan 的 api-key）。Key 和 JWT 至少填一个。")
                }
                Section {
                    SecureField("zcodejwttoken，key 查不到时兜底", text: $jwt)
                } header: {
                    Text("JWT（可选兜底）")
                }
                Section {
                    TextField("org-xxxx", text: $teamOrg)
                    TextField("proj_xxxx", text: $teamProj)
                } header: {
                    Text("企业席位（可选）")
                } footer: {
                    Text("凭据仅保存在本机应用沙盒，请勿外传。")
                }
            }
            .navigationTitle(existing == nil ? "手动添加账号" : "编辑账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") { save() }
                        .disabled(apiKey.isEmpty && jwt.isEmpty)
                }
            }
        }
        .onAppear {
            if let existing {
                name = existing.name
                apiKey = existing.apiKey ?? ""
                jwt = existing.jwt ?? ""
                teamOrg = existing.teamOrg ?? ""
                teamProj = existing.teamProj ?? ""
            }
        }
    }

    private func save() {
        var account = existing ?? LlmAccount(
            id: UUID(), name: name, apiKey: nil, jwt: nil,
            teamOrg: nil, teamProj: nil, overview: nil, lastRefreshAt: nil, lastError: nil)
        account.name = name.isEmpty ? (jwt.isEmpty ? "coding-plan 账号" : "JWT 账号") : name
        account.apiKey = apiKey.isEmpty ? nil : apiKey
        account.jwt = jwt.isEmpty ? nil : jwt
        account.teamOrg = teamOrg.isEmpty ? nil : teamOrg
        account.teamProj = teamProj.isEmpty ? nil : teamProj
        QuotaAccountStore.shared.upsert(account)
        dismiss()
    }
}
