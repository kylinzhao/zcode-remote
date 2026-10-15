import SwiftUI
import WebKit
import AppKit

/// 实例的远程页。mac 恒以桌面形态加载（CONTRACT ⑤）：无条件桌面 UA，不读 desktopMode。
struct WebScreen: View {
    let instanceID: UUID

    @ObservedObject private var store = InstanceStore.shared
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showingAdd = false

    private var instance: Instance? { store.instance(instanceID) }

    var body: some View {
        Group {
            if let instance {
                WebViewContainer(instance: instance, confirmingDelete: $confirmingDelete, showingAdd: $showingAdd)
                    .navigationTitle(instance.name)
            } else {
                // 实例已被删除
                Color.clear.onAppear { dismiss() }
            }
        }
        .sheet(isPresented: $editing) {
            if let instance {
                InstanceEditView(existing: instance)
            }
        }
        .confirmationDialog("删除实例", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除「\(instance?.name ?? "")」", role: .destructive) {
                store.remove(instanceID)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本机入口，不影响电脑端。")
        }
        .sheet(isPresented: $showingAdd) {
            AddInstanceSheet { instanceID in
                // 契约 §①：先显式关 sheet 再路由。iOS 靠「栈替换连带关 sheet」的连带效果，
                // mac NavigationStack 上未验证，必须显式关闭。
                showingAdd = false
                router.replaceTop(with: instanceID)
            }
        }
    }
}

/// 承载 WebView 与工具条（刷新/添加新实例/删除等）。mac 无下拉刷新（UIRefreshControl 无对应物）。
private struct WebViewContainer: View {
    let instance: Instance
    @Binding var confirmingDelete: Bool
    @Binding var showingAdd: Bool
    @ObservedObject private var store = InstanceStore.shared

    @State private var progress: Double = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.indigo)
            }
            ZStack {
                WebView(instance: instance,
                        reloadToken: reloadToken,
                        onProgress: { p in
                            progress = p
                            loading = p < 1.0
                        },
                        onError: { message in
                            errorText = message
                            loading = false
                        })
                if let errorText {
                    errorView(errorText)
                }
            }
        }
        // iOS 的 .principal 标题区在 mac 无效（CONTRACT ③）：标题并入窗口标题，host 以副标题承载
        .navigationSubtitle(host)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAdd = true
                    } label: { Label("添加新实例", systemImage: "plus") }

                    Button {
                        reloadToken += 1
                        errorText = nil
                    } label: { Label("刷新", systemImage: "arrow.clockwise") }

                    Button {
                        // NSPasteboard 是增量模型，不 clearContents 会追加历史（CONTRACT ③）
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.url, forType: .string)
                    } label: { Label("复制链接", systemImage: "doc.on.doc") }

                    Button {
                        if let url = URL(string: instance.url) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: { Label("在 Safari 打开", systemImage: "safari") }

                    Divider()
                    Button { confirmingDelete = true } label: { Label("删除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            store.markOpened(instance.id)
            // 用户正在看这台电脑：标记可见并消化已有的红点与提醒（mac 无屏幕常亮开关，keepScreenOn 忽略）
            TaskDone.pageVisible = true
            TaskDone.visibleInstanceID = instance.id
            TaskDone.clear(for: instance.id)
        }
        .onDisappear {
            TaskDone.pageVisible = false
            TaskDone.visibleInstanceID = nil
        }
    }

    private var host: String {
        URL(string: instance.url)?.host() ?? ""
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("无法打开页面").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                errorText = nil
                reloadToken += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - WKWebView 封装

private struct WebView: NSViewRepresentable {
    let instance: Instance
    let reloadToken: Int
    let onProgress: (Double) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 任务结束检测：页面脚本执行前注入，通过 message handler 回传 native。
        // 脚本含下拉刷新探测段，mac 无消费者但保持与 iOS/Android 副本逐字节一致（CONTRACT ①）。
        config.userContentController.addUserScript(
            WKUserScript(source: TaskDetector.source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: TaskDetector.messageHandlerName)
        config.userContentController.add(context.coordinator, name: TaskDetector.pullGateHandlerName)
        let view = WKWebView(frame: .zero, configuration: config)
        // mac 恒桌面形态（CONTRACT ⑤）：无条件桌面 UA，不读 instance.desktopMode，
        // 也不设置 iOS-only 的 preferredContentMode
        view.customUserAgent = Urls.desktopUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        context.coordinator.progressObservation = view.observe(\.estimatedProgress, options: [.new]) { obj, _ in
            let p = obj.estimatedProgress
            DispatchQueue.main.async { self.onProgress(p) }
        }
        if let url = URL(string: instance.url) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // reloadToken 变化 → 重新加载
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            nsView.reload()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 打断 message handler 对 coordinator 的强引用
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        var progressObservation: NSKeyValueObservation?
        var lastReloadToken = 0

        init(parent: WebView) {
            self.parent = parent
        }

        /// 检测脚本上报
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case TaskDetector.messageHandlerName:
                // payload: {"watchedMs":N}=正常结束；{"interrupted":true}=执行中断连
                var interrupted = false
                if let data = (message.body as? String)?.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    interrupted = obj["interrupted"] as? Bool ?? false
                }
                TaskDone.handleFinished(instanceID: parent.instance.id, interrupted: interrupted)
            case TaskDetector.pullGateHandlerName:
                // 下拉刷新探测上报：mac 无 refreshControl 可摘，收到即丢弃。
                // handler 本身保留——脚本探测段按契约逐字节不动，桥协议保持完整。
                break
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            switch url.scheme?.lowercased() {
            case "https":
                decisionHandler(.allow)
            case "http":
                parent.onError("明文 http 链接已被阻止（安全策略）。")
                decisionHandler(.cancel)
            case "mailto", "tel", "sms", "geo", "intent":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
                     withError error: Error) {
            parent.onError(Self.friendly(error))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            parent.onError(Self.friendly(error))
        }

        private static func friendly(_ error: Error) -> String {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case NSURLErrorNotConnectedToInternet:
                    return "网络连接失败。请检查手机网络，并确认电脑端 ZCode 正在运行、远程访问已开启。"
                case NSURLErrorTimedOut:
                    return "连接超时。请确认电脑端 ZCode 正在运行。"
                default:
                    break
                }
            }
            return "加载失败：\(ns.localizedDescription)"
        }
    }
}
