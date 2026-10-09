import SwiftUI

/// 添加/编辑实例。onSaved(newInstance) 在新增时回调（用于直接打开）。
struct InstanceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InstanceStore.shared

    let existing: Instance?
    var onSaved: ((Instance) -> Void)?

    @State private var name: String = ""
    @State private var urlText: String = ""
    // 常亮/桌面形态两个开关在 mac 上无意义已隐藏；state 仅为保存时把原值原样写回，
    // 不丢 iOS 端共享 JSON 里的设置（CONTRACT ③⑤）
    @State private var keepScreenOn = false
    @State private var desktopMode = true
    @State private var invalidTip: String?
    @State private var showingRebind = false
    @State private var scannedTip: String?

    init(existing: Instance?, suggestedURL: String? = nil, onSaved: ((Instance) -> Void)? = nil) {
        self.existing = existing
        self.onSaved = onSaved
        _urlText = State(initialValue: suggestedURL ?? existing?.url ?? "")
        _name = State(initialValue: existing?.name ?? suggestedURL.flatMap(Urls.suggestName) ?? "")
        _keepScreenOn = State(initialValue: existing?.keepScreenOn ?? false)
        _desktopMode = State(initialValue: existing?.desktopMode ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("实例名称（如：家里 MacBook）", text: $name)
                    TextField("https://zcode.z.ai/remote/…", text: $urlText)
                        .autocorrectionDisabled()
                    if existing != nil {
                        Button {
                            showingRebind = true
                        } label: {
                            // mac 无相机：iOS「扫码重新绑定」改为「换链接」（粘贴/二维码截图）
                            Label("换链接", systemImage: "qrcode.viewfinder")
                        }
                    }
                    if let invalidTip {
                        Text(invalidTip)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let scannedTip {
                        Text(scannedTip)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("实例")
                } footer: {
                    Text(existing == nil
                         ? "粘贴电脑端 ZCode「远程访问」的 https 网址，或粘贴/拖入二维码截图。网址内含访问凭证，仅保存在本机应用沙盒，请勿外传。"
                         : "链接失效（电脑端重启/重新生成）时，点「换链接」换新链接；名称、提醒设置保持不变。")
                }
            }
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle(existing == nil ? "添加实例" : "编辑实例")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingRebind) {
                RebindSheet { url in
                    urlText = url
                    invalidTip = nil
                    scannedTip = "已识别新链接，保存后生效"
                }
            }
        }
    }

    private func save() {
        guard let url = Urls.sanitize(urlText) else {
            invalidTip = "网址无效：需要 https:// 开头的完整链接"
            return
        }
        var instance = existing ?? Instance(
            id: UUID(), name: "", url: url, keepScreenOn: false,
            desktopMode: true, // 新建恒桌面形态（CONTRACT ⑤）
            createdAt: Date(), lastOpenedAt: nil)
        instance.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (Urls.suggestName(url) ?? "ZCode 实例")
            : name.trimmingCharacters(in: .whitespaces)
        instance.url = url
        // 开关已隐藏：把 init 时快照的原值原样写回，保持 iOS 端数据不受编辑影响
        instance.keepScreenOn = keepScreenOn
        instance.desktopMode = desktopMode
        let isNew = store.upsert(instance)
        dismiss()
        if isNew { onSaved?(instance) }
    }
}
