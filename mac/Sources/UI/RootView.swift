import SwiftUI
import AppKit

/// 导航路由：RootView 持有栈，WebScreen 可替换栈顶（页面内添加新实例时切换）。
@MainActor
final class Router: ObservableObject {
    @Published var path = NavigationPath()

    func open(_ id: UUID) {
        path.append(id)
    }

    /// 替换当前栈顶（从页面内切换到新实例，返回栈保持 列表→页面）。
    func replaceTop(with id: UUID) {
        guard !path.isEmpty else {
            path.append(id)
            return
        }
        path.removeLast()
        path.append(id)
    }
}

struct RootView: View {
    @ObservedObject private var store = InstanceStore.shared
    @StateObject private var router = Router()
    @State private var showingAdd = false
    @State private var showingQuota = false
    @State private var editing: Instance?
    @State private var didAutoOpen = false
    private let autoOpenURL: String?

    init(autoOpenURL: String?) {
        self.autoOpenURL = autoOpenURL
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if store.instances.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("ZCode Remote")
            .toolbar {
                // macOS 无 .navigation placement（编译可过但布局无效），额度入口按契约用 .automatic（CONTRACT ③）
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingQuota = true
                    } label: {
                        Image(systemName: "chart.bar")
                    }
                    .accessibilityLabel("账号额度")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加实例")
                }
            }
            .navigationDestination(isPresented: $showingQuota) {
                QuotaView()
            }
            .navigationDestination(for: UUID.self) { id in
                WebScreen(instanceID: id)
            }
            // mac 上不能依赖 iOS「replaceTop 连带关闭 sheet」的栈替换副作用：
            // 回调里先显式关 sheet 再路由（CONTRACT ① 消费方式）
            .sheet(isPresented: $showingAdd) {
                AddInstanceSheet { instanceID in
                    showingAdd = false
                    router.open(instanceID)
                }
            }
            .sheet(item: $editing) { instance in
                InstanceEditView(existing: instance)
            }
            .task {
                // CI/调试：启动参数 -ZCODE_AUTOPEN_URL 自动添加并打开
                if let raw = autoOpenURL, let url = Urls.sanitize(raw) {
                    let instance: Instance
                    if let existing = store.instance(withURL: url) {
                        instance = existing
                    } else {
                        instance = Instance(
                            id: UUID(), name: Urls.suggestName(url) ?? "新实例", url: url,
                            keepScreenOn: false,
                            desktopMode: true, // mac 恒桌面形态，新建一律写 true（CONTRACT ⑤）
                            createdAt: Date(), lastOpenedAt: nil)
                        store.upsert(instance)
                    }
                    router.open(instance.id)
                    didAutoOpen = true
                } else if !didAutoOpen {
                    // 冷启动直达：打开最近一次使用的实例，省去再选一次主机。
                    // App 在后台被系统杀掉后再次打开即冷启动（导航栈已丢）；
                    // 进程未死的前台切换由系统保留页面栈，不会重新进入 .task。
                    // 全部实例都从未打开过时，仅一台则沿用旧的单实例直达。
                    didAutoOpen = true
                    if let target = store.instances.lastOpened ?? store.instances.only {
                        router.open(target.id)
                    }
                }
            }
        }
        .environmentObject(router)
    }

    private var list: some View {
        List {
            ForEach(store.instances) { instance in
                Button {
                    store.markOpened(instance.id)
                    TaskDone.clear(for: instance.id)
                    router.open(instance.id)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(instance.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(host(of: instance)) · \(Date.relative(instance.lastOpenedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if instance.unreadDone == true {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                                .accessibilityLabel("这台电脑有任务已完成的提醒")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .contextMenu {
                    Button { editing = instance } label: { Label("编辑", systemImage: "pencil") }
                    Button {
                        // NSPasteboard 是增量模型：不 clearContents 会把内容追加进历史（CONTRACT ③）
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.url, forType: .string)
                    } label: { Label("复制链接", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { store.remove(instance.id) } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .listStyle(.inset) // insetGrouped 是 iOS-only；inset 实测可编译且观感最接近（CONTRACT ③）
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("还没有实例")
                .font(.title3.weight(.semibold))
            // mac 无相机扫码：文案改为粘贴链接 / 识别二维码截图
            Text("点右上角「＋」，粘贴电脑端 ZCode「远程访问」的链接，或拖入/粘贴二维码截图")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func host(of instance: Instance) -> String {
        URL(string: instance.url)?.host() ?? instance.url
    }
}
