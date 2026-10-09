import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// 账号额度页：多账号列表 + 额度进度条 + 扫码/截图/手动导入 + 刷新（与 Android 版 QuotaActivity 对齐）。
/// mac 适配（见 CONTRACT.md ③）：insetGrouped→inset、无下拉刷新（保留工具栏刷新钮）、
/// Color(uiColor:)→Color(nsColor:)；导入渠道在相机扫码之外新增二维码截图解码（桌面端无手持相机习惯）。
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
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("账号额度")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingScan = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("扫码导入账号")
            }
            // .navigation placement 在 macOS 布局无效（CONTRACT.md ③），改 .automatic 落在工具栏
            ToolbarItem(placement: .automatic) {
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
        .listStyle(.inset)
        // iOS 的 .refreshable 是下拉刷新手势，mac 无对应交互（CONTRACT.md ③），刷新统一走工具栏按钮
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("还没有账号")
                .font(.title3.weight(.semibold))
            Text("在电脑端运行导出脚本生成账号二维码，点右上角「＋」扫码或导入二维码截图；或手动粘贴 API Key")
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
                .fixedSize()
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

/// 二维码截图解码：CoreImage 的 CIDetector(CIDetectorTypeQRCode)。
/// 契约 §① 只把 ScannerBox/requestCameraAccess 归 UI 模块共用，未规定截图解码工具的归属，
/// 故在本模块内自含一份（类型名加 Quota 前缀，避免与界面模块将来的同名顶层符号冲突）。
enum QuotaQRImage {
    /// 从任意 NSImage（文件/剪贴板截图）解出第一个二维码载荷；无二维码返回 nil。
    static func payload(from image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        for feature in detector?.features(in: ci) ?? [] {
            if let qr = feature as? CIQRCodeFeature,
               let s = qr.messageString?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

/// 扫码导入账号：识别账号 JSON → 同名去重合并；无相机时退化为粘贴/截图导入。
/// mac 适配：相机取流复用 UI 模块的 ScannerBox（契约 §① 唯一例外）；
/// 在位检测用 AVCaptureDevice（mac 无 DataScannerViewController.isAvailable 对应物）。
struct QuotaScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pasteText = ""
    @State private var invalidTip: String?
    @State private var cameraGranted = false
    @State private var scannerAvailable = AVCaptureDevice.default(for: .video) != nil
    @State private var resultTip: String?
    @State private var showingImagePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scannerAvailable {
                    ScannerBox(granted: $cameraGranted) { payload in
                        handlePayload(payload)
                    }
                    // mac sheet 依内容定大小，不能像 iOS 那样 maxHeight .infinity 撑满
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("此设备无法使用相机扫码，请粘贴账号 JSON 或导入二维码截图")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("手动粘贴账号 JSON").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("{\"accounts\":[…]}", text: $pasteText, axis: .vertical)
                        .autocorrectionDisabled()
                        .font(.footnote)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                    HStack {
                        Button("导入") { handlePayload(pasteText) }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button {
                            showingImagePicker = true
                        } label: {
                            Label("导入二维码截图…", systemImage: "photo")
                        }
                        Button {
                            importFromPasteboard()
                        } label: {
                            Label("粘贴截图", systemImage: "clipboard")
                        }
                    }
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
            .frame(minWidth: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("扫码导入账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result {
                    importQRImage(at: url)
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

    /// fileImporter 交来的 URL 在沙盒安全域外，须先取读取权限再解码。
    private func importQRImage(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else {
            invalidTip = "无法读取所选图片"
            resultTip = nil
            return
        }
        importQR(image: image)
    }

    /// 剪贴板截图（⇧⌃⌘4 截进剪贴板）是最顺手的桌面导入路径。
    private func importFromPasteboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
            invalidTip = "剪贴板里没有图片（截图复制到剪贴板请用 ⇧⌃⌘4）"
            resultTip = nil
            return
        }
        importQR(image: image)
    }

    private func importQR(image: NSImage) {
        guard let payload = QuotaQRImage.payload(from: image) else {
            invalidTip = "截图里没有识别到二维码"
            resultTip = nil
            return
        }
        handlePayload(payload)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(apiKey.isEmpty && jwt.isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
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
