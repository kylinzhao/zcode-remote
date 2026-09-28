import SwiftUI
import UIKit

/// 添加/编辑实例。onSaved(newInstance) 在新增时回调（用于直接打开）。
struct InstanceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InstanceStore.shared

    let existing: Instance?
    var onSaved: ((Instance) -> Void)?

    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var keepScreenOn = false
    @State private var desktopMode = false
    @State private var invalidTip: String?
    @State private var showingRebindScan = false
    @State private var scannedTip: String?

    init(existing: Instance?, suggestedURL: String? = nil, onSaved: ((Instance) -> Void)? = nil) {
        self.existing = existing
        self.onSaved = onSaved
        _urlText = State(initialValue: suggestedURL ?? existing?.url ?? "")
        _name = State(initialValue: existing?.name ?? suggestedURL.flatMap(Urls.suggestName) ?? "")
        _keepScreenOn = State(initialValue: existing?.keepScreenOn ?? false)
        _desktopMode = State(initialValue: existing?.desktopMode ?? (UIDevice.current.userInterfaceIdiom == .pad))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("实例名称（如：家里 MacBook）", text: $name)
                    TextField("https://zcode.z.ai/remote/…", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if existing != nil {
                        Button {
                            showingRebindScan = true
                        } label: {
                            Label("扫码重新绑定", systemImage: "qrcode.viewfinder")
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
                        ? "粘贴电脑端 ZCode「远程访问」扫码得到的 https 网址。网址内含访问凭证，仅保存在本机应用沙盒，请勿外传。"
                        : "链接失效（电脑端重启/重新生成）时，点「扫码重新绑定」换新链接；名称、提醒设置保持不变。")
                }
                Section {
                    Toggle("打开时保持屏幕常亮", isOn: $keepScreenOn)
                    Toggle("以桌面版网页加载（PC 形式）", isOn: $desktopMode)
                } footer: {
                    Text("iPad 默认以桌面形态加载；连接电脑后可获得更宽的桌面布局。")
                }
            }
            .navigationTitle(existing == nil ? "添加实例" : "编辑实例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingRebindScan) {
                RebindScanSheet { url in
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
            desktopMode: UIDevice.current.userInterfaceIdiom == .pad,
            createdAt: Date(), lastOpenedAt: nil)
        instance.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (Urls.suggestName(url) ?? "ZCode 实例")
            : name.trimmingCharacters(in: .whitespaces)
        instance.url = url
        instance.keepScreenOn = keepScreenOn
        instance.desktopMode = desktopMode
        let isNew = store.upsert(instance)
        dismiss()
        if isNew { onSaved?(instance) }
    }
}
