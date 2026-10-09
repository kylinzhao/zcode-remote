import SwiftUI

/// 编辑实例内的「换链接」（iOS RebindScanSheet 的 mac 对应物）：粘贴新链接或识别二维码截图，
/// 只把识别到的远程链接回传，替换网址与保存仍由编辑页完成。
struct RebindSheet: View {
    let onURL: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pasteText = ""
    @State private var invalidTip: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("粘贴新链接").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://zcode.z.ai/remote/…", text: $pasteText)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { handlePayload(pasteText) }
                        Button("使用") { handlePayload(pasteText) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                QRDropZone(invalidTip: $invalidTip) { raw in
                    handlePayload(raw)
                }
                if let invalidTip {
                    Text(invalidTip).font(.footnote).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 520, minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("换链接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 判定链照搬 iOS RebindScanSheet.handlePayload：提取 → 清洗 → 回传。
    /// 空输入清提示沿 ScanSheet 的文本路径语义；失败文案沿 iOS，仅把「对准二维码」换成 mac 的粘贴/截图动作。
    private func handlePayload(_ raw: String) {
        guard let candidate = Urls.extractRemoteURL(raw),
              let url = Urls.sanitize(candidate) else {
            invalidTip = raw.isEmpty ? nil : "二维码里没有 ZCode 远程链接，请粘贴电脑端「远程访问」的链接或二维码截图"
            return
        }
        dismiss()
        onURL(url)
    }
}
