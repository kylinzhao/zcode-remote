import SwiftUI
import WebKit
import UIKit

/// 实例的 WebView 页。iPad 或开启"桌面版"时用 macOS UA + desktop content mode。
struct WebScreen: View {
    let instanceID: UUID

    @ObservedObject private var store = InstanceStore.shared
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showingScan = false

    private var instance: Instance? { store.instance(instanceID) }

    var body: some View {
        Group {
            if let instance {
                WebViewContainer(instance: instance, confirmingDelete: $confirmingDelete, showingScan: $showingScan)
                    .navigationTitle(instance.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
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
        .sheet(isPresented: $showingScan) {
            ScanSheet { instanceID in
                // 先替换栈顶（本页被替换，sheet 随之消失），返回键直达列表
                router.replaceTop(with: instanceID)
                showingScan = false
            }
        }
    }
}

/// 承载 WebView 与工具条（刷新/添加新实例/删除等）。
private struct WebViewContainer: View {
    let instance: Instance
    @Binding var confirmingDelete: Bool
    @Binding var showingScan: Bool
    @ObservedObject private var store = InstanceStore.shared
    @EnvironmentObject private var router: Router

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
                        },
                        onPullRefresh: {
                            // 下拉刷新走既有 reloadToken 通道，与菜单里的"刷新"同一条路
                            errorText = nil
                            reloadToken += 1
                        })
                if let errorText {
                    errorView(errorText)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(instance.name).font(.subheadline.weight(.semibold))
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingScan = true
                    } label: { Label("添加新实例", systemImage: "plus") }

                    Button {
                        reloadToken += 1
                        errorText = nil
                    } label: { Label("刷新", systemImage: "arrow.clockwise") }

                    Button {
                        UIPasteboard.general.string = instance.url
                    } label: { Label("复制链接", systemImage: "doc.on.doc") }

                    Button {
                        if let url = URL(string: instance.url) {
                            UIApplication.shared.open(url)
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
            UIApplication.shared.isIdleTimerDisabled = instance.keepScreenOn
            store.markOpened(instance.id)
            // 用户正在看这台电脑：标记可见并消化已有的红点与提醒
            TaskDone.pageVisible = true
            TaskDone.clear(for: instance.id)
        }
        .onDisappear {
            TaskDone.pageVisible = false
            if instance.keepScreenOn {
                UIApplication.shared.isIdleTimerDisabled = false
            }
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
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - WKWebView 封装

private struct WebView: UIViewRepresentable {
    let instance: Instance
    let reloadToken: Int
    let onProgress: (Double) -> Void
    let onError: (String) -> Void
    let onPullRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let desktop = instance.desktopMode
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        // 任务结束检测：页面脚本执行前注入，通过 message handler 回传 native
        config.userContentController.addUserScript(
            WKUserScript(source: TaskDetector.source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: TaskDetector.messageHandlerName)
        let view = WKWebView(frame: .zero, configuration: config)
        if desktop {
            view.customUserAgent = Urls.desktopUserAgent
        }
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        // 下拉刷新：页面卡死时的就地恢复手段
        let refresh = UIRefreshControl()
        refresh.tintColor = .indigo
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullRefreshTriggered), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        context.coordinator.progressObservation = view.observe(\.estimatedProgress, options: [.new]) { obj, _ in
            let p = obj.estimatedProgress
            DispatchQueue.main.async { self.onProgress(p) }
        }
        if let url = URL(string: instance.url) {
            view.load(URLRequest(url: url))
        }
        context.coordinator.webView = view
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // reloadToken 变化 → 重新加载
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            uiView.reload()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // 打断 message handler 对 coordinator 的强引用
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        // 下拉刷新随 WebView 一起拆掉
        coordinator.cancelRefreshSafety()
        uiView.scrollView.refreshControl = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        var progressObservation: NSKeyValueObservation?
        var lastReloadToken = 0
        weak var webView: WKWebView?
        private var refreshSafetyWork: DispatchWorkItem?

        init(parent: WebView) {
            self.parent = parent
        }

        /// 下拉刷新触发
        @objc func pullRefreshTriggered() {
            parent.onPullRefresh()
            cancelRefreshSafety()
            // 页面卡死时 didFinish 永远不来，超时兜底收起指示器
            let work = DispatchWorkItem { [weak self] in
                self?.endPullRefresh()
            }
            refreshSafetyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        }

        func endPullRefresh() {
            cancelRefreshSafety()
            webView?.scrollView.refreshControl?.endRefreshing()
        }

        func cancelRefreshSafety() {
            refreshSafetyWork?.cancel()
            refreshSafetyWork = nil
        }

        /// 检测脚本上报任务结束
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == TaskDetector.messageHandlerName else { return }
            TaskDone.handleFinished(instanceID: parent.instance.id)
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
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
                     withError error: Error) {
            endPullRefresh()
            parent.onError(Self.friendly(error))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            endPullRefresh()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            endPullRefresh()
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
