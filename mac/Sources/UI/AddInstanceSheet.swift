import SwiftUI

/// 添加实例（iOS ScanSheet 的 mac 对应物）。mac 无相机扫码：粘贴远程链接为主，
/// 拖入/粘贴二维码截图解码兜底。
/// 回调契约（顺序与 iOS ScanSheet.handlePayload 一致，CONTRACT ①）：
/// 1) upsert 去重；2) markOpened（决定 lastOpened 排序与冷启动直达，不可漏）；
/// 3) 恰好一次 onSaved(id)。关闭 sheet 由呈现方负责：回调里先置 isPresented = false 再路由。
struct AddInstanceSheet: View {
    let onSaved: (UUID) -> Void

    init(onSaved: @escaping (UUID) -> Void) {
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InstanceStore.shared
    @State private var pasteText = ""
    @State private var invalidTip: String?
    /// 识别成功后不再接受新输入，保证 onSaved 恰好一次（呈现方关 sheet 有细微延迟）
    @State private var settled = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("粘贴远程链接").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://zcode.z.ai/remote/…", text: $pasteText)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { handlePayload(pasteText) }
                        Button("添加") { handlePayload(pasteText) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("或识别二维码截图").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                QRDropZone(invalidTip: $invalidTip) { raw in
                    handlePayload(raw)
                }
                if let invalidTip {
                    Text(invalidTip).font(.footnote).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 520, minHeight: 400)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("添加实例")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 判定链与去重逻辑照搬 iOS ScanSheet.handlePayload（含 settled 防重入）；
    /// 仅删掉末尾的 dismiss——mac 版关闭动作归呈现方（契约消费方式）。
    private func handlePayload(_ raw: String) {
        guard !settled else { return }
        guard let candidate = Urls.extractRemoteURL(raw),
              let url = Urls.sanitize(candidate) else {
            invalidTip = raw.isEmpty ? nil : "二维码/文本里没有 ZCode 远程链接：\(raw.prefix(24))"
            return
        }
        settled = true
        let instance: Instance
        if let existing = store.instance(withURL: url) {
            instance = existing
        } else {
            instance = Instance(
                id: UUID(),
                name: Urls.suggestName(url) ?? "ZCode 实例",
                url: url,
                keepScreenOn: false,
                desktopMode: true, // mac 恒桌面形态（CONTRACT ⑤）
                createdAt: Date(),
                lastOpenedAt: nil)
            store.upsert(instance)
        }
        store.markOpened(instance.id)
        onSaved(instance.id)
    }
}
