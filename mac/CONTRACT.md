# mac/CONTRACT.md — macOS 版接口契约

> macOS 版（用户在公司 Mac 上遥控家里电脑的 ZCode）由四个模块并行开发，本文是**唯一契约**。
> 各模块工程师只凭本文即可工作；发现契约本身有问题，找基础移植工程师改契约，不要单边绕开。
> 所有代码注释用中文、只解释「为什么」，与 ios/ZCodeRemote/ 既有风格一致。

## 0. 总则与构建

- 源码根：`mac/Sources/`，按模块分目录；build-mac.sh 把**全部** `.swift` 编译为**单一目标**
  （单编译单元）。因此模块边界不是 Swift module 边界，靠目录 + 本文 API 约定执行：
  **跨目录只能引用本文第 ① 节列出的符号**，未列出的类型/成员一律视为其他模块私有。
- 默认访问级别 internal 即可，不要求 public。
- 构建/自查：`bash mac/build-mac.sh` → `mac/build/ZCodeRemote.app`（ad-hoc 签名，`open` 即可运行）。
  语法快查：`swiftc -parse <文件>`（不做导入解析，不受本机工具链问题影响）。
- 最低系统 macOS 14.0（见 mac/Info.plist）；SwiftUI 的 `NavigationStack`/`navigationDestination`
  在 macOS 13+ 可用，无版本障碍。
- 三条铁律：不碰 `ios/`、`app/`、`desktop-hook/`；不改 `mac/build-mac.sh`、`mac/Info.plist`、
  本契约；`mac/Sources/Core/` 只有基础移植工程师能改（唯一例外见第 ② 节）。

## ① 共享类型与公开 API（逐个签名）

以下签名**逐字有效**，来自已落地的 `mac/Sources/Core/Models.swift`（自 ios/ZCodeRemote/Models.swift
原样移植，Foundation-only）与各模块必须提供的接缝。签名不得增删改参数；行为疑问以 iOS 版对应实现为准。

### Core（已就位，勿动）

```swift
struct Instance: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var keepScreenOn: Bool
    var desktopMode: Bool        // mac 上不参与逻辑，仅为兼容既有 JSON（见第 ⑤ 节）
    var createdAt: Date
    var lastOpenedAt: Date?
    var unreadDone: Bool?
}

final class InstanceStore: ObservableObject {
    static let shared: InstanceStore          // 单例；仅在主线程读写
    @Published private(set) var instances: [Instance]
    func instance(_ id: UUID) -> Instance?
    func instance(withURL url: String) -> Instance?
    @discardableResult func upsert(_ instance: Instance) -> Bool   // 新增或更新；返回是否为新增
    func markOpened(_ id: UUID)
    func markDone(_ id: UUID)
    func clearDone(_ id: UUID)
    var unreadDoneCount: Int { get }
    func remove(_ id: UUID)
}

enum Urls {
    static func sanitize(_ raw: String) -> String?          // 清洗链接，仅接受 https
    static func suggestName(_ urlString: String) -> String? // 从 name 参数建议实例名
    static func extractRemoteURL(_ text: String) -> String? // 从任意文本提取远程链接
    static let desktopUserAgent: String                     // macOS Safari 桌面 UA
}

extension Array where Element == Instance {
    var only: Element? { get }        // 恰好一个元素时返回它
    var lastOpened: Element? { get }  // 最近打开过的实例（冷启动直达用）
}

extension Date {
    static func relative(_ date: Date?) -> String  // "3分钟前" / "未打开过"
}
```

### UI ↔ Web 接缝（Web 模块必须提供的）

```swift
/// 实例的远程页。UI 以 navigationDestination(for: UUID.self) 呈现。
struct WebScreen: View {
    init(instanceID: UUID)
}
/// WebScreen 内部依赖（经 environmentObject / sheet 注入，见下）：Router、InstanceEditView、AddInstanceSheet。

/// 任务结束提醒 native 侧（iOS 版在 TaskDetector.swift，mac 归 Web 模块）。
/// 角标/通知用 UserNotifications；可见性两个 Bool 由 WebScreen 与 App 入口维护。
@MainActor
enum TaskDone {
    static var pageVisible: Bool                  // 远程页是否在窗口层级（WebScreen onAppear/onDisappear）
    static var appActive: Bool                    // App 是否前台（入口 scenePhase == .active）
    static var userWatching: Bool { get }         // pageVisible && appActive
    static func requestAuthorization() -> Void
    static func handleFinished(instanceID: UUID, interrupted: Bool = false) -> Void
    static func clear(for instanceID: UUID) -> Void
    static func syncBadge() -> Void               // Dock 角标 = 未读实例数
}
```

`TaskDetector`（注入脚本与 handler 常量 `messageHandlerName` / `pullGateHandlerName` / `source`）
是 Web 模块内部实现，非跨模块 API——但注意第 ③ 节：脚本里的下拉刷新探测段在 mac 上无消费者，
脚本本体保持与 iOS 逐字节一致（Android 端有同步副本，改一处要改三处）。

### UI ↔ UI（UI 模块必须提供的，Web 模块按此调用）

```swift
/// 导航路由：UI 模块定义并经 .environmentObject(router) 注入；WebScreen 用它切换实例。
@MainActor
final class Router: ObservableObject {
    @Published var path: NavigationPath
    func open(_ id: UUID)                 // path.append(id)
    func replaceTop(with id: UUID)        // 替换栈顶（页面内添加新实例时切换，返回栈保持 列表→页面）
}

/// 添加/编辑实例。WebScreen 工具菜单「编辑」以 sheet 呈现。
/// suggestedURL/onSaved 语义同 iOS：suggestedURL 预填链接；新增保存成功时回调 onSaved(新实例)。
struct InstanceEditView: View {
    init(existing: Instance?, suggestedURL: String? = nil, onSaved: ((Instance) -> Void)? = nil)
}

/// 添加实例入口（iOS ScanSheet 的 mac 对应物）：扫码/手动粘贴，识别 → 去重(upsert) → 回调实例 id。
/// 相机不可用（无摄像头/无权限）时退化为纯粘贴表单。
/// 回调契约（顺序与 iOS ScanSheet.handlePayload 一致，ios/ZCodeRemote/ScanSheet.swift:99-103）：
/// 1) upsert 去重（新实例入库或按 URL 命中既有实例）；2) `InstanceStore.shared.markOpened(id)`——
///    该副作用决定 lastOpened 排序与第 ④ 节冷启动直达打开谁，mac 版**必须保留**，漏调则
///    「添加后重启 App」不再直达该实例，与 iOS 行为分叉且合编不报错；3) 恰好一次 onSaved(id)，
///    参数为「新入库或按 URL 去重命中的既有」实例 id。
/// 关闭 sheet 由呈现方负责：回调里**先置 isPresented = false 再路由**（见下方消费方式）。
/// 不得照抄 iOS 依赖的「replaceTop 连带关闭 sheet」行为——那是 iOS 栈替换的连带效果
/// （ios WebScreen.swift:46 注释），mac NavigationStack 上未验证，必须显式关闭。
struct AddInstanceSheet: View {
    init(onSaved: @escaping (UUID) -> Void)
}

/// 摄像头扫码封装与相机权限函数：**UI 模块所有**，Quota 模块的扫码导入共用。
/// 单一编译目标下全仓只允许这一份定义（照抄 iOS 的顶层符号名，两边各自实现会
/// invalid redeclaration，且只有最后合编才爆，务必按本条归属执行）。
/// 实现自由（VisionKit DataScanner 为 iOS-only，用 AVCaptureSession + NSViewRepresentable
/// 自建，AVCapture 系 API 在 macOS 可编译已实测），对外签名与语义固定：
func requestCameraAccess() async -> Bool
    // 已授权 true；未决定则弹系统询问；被拒 false（语义同 ios/ZCodeRemote/ScanSheet.swift:108）
struct ScannerBox: NSViewRepresentable {
    init(granted: Binding<Bool>, onPayload: @escaping (String) -> Void)
    // granted 变 true 后开始取流；仅识别二维码；识别到 payload 回调一次，
    // 同一 payload 不重复回调、换了新码仍会回调（重新绑定场景需要继续扫）
}
```

消费方式（与 iOS 版对齐，见 ios/ZCodeRemote/RootView.swift:72-77 与 WebScreen.swift:44-50；注意两处都**先显式关 sheet 再路由**）：

- RootView「＋」→ `.sheet(isPresented: $showingAdd) { AddInstanceSheet { id in showingAdd = false; router.open(id) } }`
- WebScreen 菜单「添加新实例」→ `.sheet(isPresented: $showingAdd) { AddInstanceSheet { id in showingAdd = false; router.replaceTop(with: id) } }`

### UI ↔ Quota 接缝（Quota 模块必须提供的）

```swift
/// 账号额度页（ios/ZCodeRemote/QuotaView.swift 的移植）。无参呈现：
/// .navigationDestination(isPresented:) { QuotaView() }
struct QuotaView: View { init() }
```

Quota 模块其余类型（QuotaAccountStore、LlmAccount、QuotaClient、QuotaImport 等）为模块内部实现；
`QuotaAccountStore` 与 InstanceStore 同样的单例 + Application Support JSON 模式，自 macOS 版自带
的 mac/Sources/Quota/ 内实现，不复用 Core。

**唯一例外**：扫码导入页（QuotaScanSheet 的 mac 对应物）直接引用上列 `ScannerBox` 与
`requestCameraAccess()`（UI 模块提供，全仓唯一定义）——这是 Quota 模块允许引用的仅有的两个
UI 模块符号，此外不得引用 UI 模块任何符号，也**禁止在 mac/Sources/Quota/ 重名定义这两个符号**
（iOS 顶层同名符号 ScanSheet.swift:108/117 双模块共用的旧格局，在 mac 单一编译目标下会
invalid redeclaration，且只在合编时爆）。UI 模块的 ScannerBox 就位前，Quota 工程师用
`swiftc -parse` 做语法自查或临时本地 stub 开发，合编前删除 stub。

## ② 文件归属与禁止触碰范围

| 模块 | 目录 | 可创建/修改 | 禁止 |
| --- | --- | --- | --- |
| Web（Web 工程师） | `mac/Sources/Web/` | WebScreen、WebView 封装（NSViewRepresentable）、TaskDetector、TaskDone | 其他任何目录 |
| 界面（UI 工程师） | `mac/Sources/UI/` | App 入口（@main）、RootView、Router、InstanceEditView、AddInstanceSheet、RebindSheet，以及**共享扫码封装 `ScannerBox` + `requestCameraAccess()`（§① 列出的签名，供 Quota 复用）**等 | 其他任何目录；**例外：必须删除 `mac/Sources/Core/PlaceholderMain.swift`**（自带真正 @main 入口时，两个 @main 无法共存。这是 UI 模块唯一允许触碰 Core 的动作，仅限删除该文件） |
| 额度（Quota 工程师） | `mac/Sources/Quota/` | QuotaView、QuotaClient、QuotaModels、QuotaScanSheet 等 | 其他任何目录；**不得重名定义 `ScannerBox` / `requestCameraAccess`（归 UI 模块，见 §①）** |
| Core（基础移植工程师） | `mac/Sources/Core/` | Models.swift 等 | — |

公共资产：`mac/build-mac.sh`、`mac/Info.plist`、`mac/CONTRACT.md` 只归基础移植工程师；
所有人禁止改 `ios/`、`app/`、`desktop-hook/`。目录内的文件名可自定（Web/UI/Quota），
但第 ① 节点名的类型必须在各自模块目录下的某文件中定义、签名逐字一致——所有人同时编译，
签名漂移会当场把其他模块编挂。

## ③ UIKit → AppKit 移植对照

WKWebView 在 macOS 上原生可用，`window.webkit.messageHandlers` 桥两侧一致；差异全在 UI 层：

| iOS（ios/ZCodeRemote/） | macOS（mac/Sources/） | 说明 |
| --- | --- | --- |
| `UIPasteboard.general.string = s` | `NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)` | NSPasteboard 是增量模型，不 clearContents 会追加历史 |
| `UIApplication.shared.open(url)` | `NSWorkspace.shared.open(url)` | 外部 scheme（mailto/tel 等）与「在 Safari 打开」同此 |
| `UIViewRepresentable`（makeUIView/updateUIView/dismantleUIView） | `NSViewRepresentable`（makeNSView/updateNSView/dismantleNSView） | Coordinator 模式照搬 |
| `UIRefreshControl` + `zcodePullGate` 防误触 | **整段删除** | mac 无下拉刷新对应物；保留菜单「刷新」（reloadToken 通道）。注入脚本里的探测段留着无妨（无 handler 即 no-op），但 native 侧 pullGate/refreshControl 代码全部不要 |
| `UIApplication.shared.isIdleTimerDisabled`（屏幕常亮） | **不需要** | mac 接电源、系统设置管休眠；onAppear/onDisappear 里的常亮开关整段去掉，`Instance.keepScreenOn` 字段保留、编辑页是否保留开关由 UI 模块定（默认建议隐藏，保存时保留原值） |
| `Color(uiColor: .systemGroupedBackground)` / `.systemBackground` | `Color(nsColor: .windowBackgroundColor)` / `.controlBackgroundColor` | 语义对应即可，深色模式同样跟随系统 |
| `UIDevice.current.userInterfaceIdiom == .pad`（desktopMode 默认值） | **恒 true 语义** | 见第 ⑤ 节：新建实例 `desktopMode` 写 true，Web 模块不读该字段 |
| `confirmationDialog` | 可用 | macOS 12+ 直接用；呈现样式与 iOS 略异，行为一致 |
| `toolbar` + `ToolbarItem(placement:)` | 可用，**placement 有差异** | `.navigation`/`.principal` 在 macOS 不可用（编译可过但布局无效）：列表页左上「额度」用 `.automatic` 或 `.navigation(.mac)` 之外的既有 placement，详情页标题区并入窗口标题 `.navigationTitle(instance.name)`；`.primaryAction`/`.confirmationAction`/`.cancellationAction` 两侧通用 |
| `navigationBarTitleDisplayMode(.inline)` | **删除** | macOS 无对应概念，标题由窗口标题栏承载 |
| VisionKit `DataScannerViewController`（扫码） | **不可用（iOS-only）** | 扫码统一走 UI 模块的 `ScannerBox` + `requestCameraAccess()`（签名见 §①；AVCaptureSession + NSViewRepresentable 自建，AVCapture 系 API 在 macOS 可编译已实测）；Quota 扫码导入复用同一封装，禁止重名定义。相机权限 key `NSCameraUsageDescription` **已由基础工程师写入 mac/Info.plist**（macOS 10.14+ 缺该 key 访问相机会被系统直接终止），模块无需再动 |
| `.toolbarBackground(.visible, for: .navigationBar)`（ios WebScreen.swift:24） | **删除该修饰符** | `for: .navigationBar` 在 macOS 直接编译失败（swiftc -typecheck 实测 `'navigationBar' is unavailable in macOS`）；注意复核时常被建议的 `.window` **同样编不过**（实测 `ToolbarPlacement has no member 'window'`）。macOS 窗口工具条本就常显，确需显式控制用单参版 `.toolbarBackground(.visible)`（实测可编译） |
| `.listStyle(.insetGrouped)`（ios RootView.swift:146、QuotaView.swift:56） | `.listStyle(.inset)` | `insetGrouped` 在 macOS 编译失败（实测 unavailable）；`.inset` 实测可编译，观感最接近；用默认样式（不写 listStyle）亦可 |
| `.keyboardType(.URL)`、`.textInputAutocapitalization(.never)`（ios InstanceEditView.swift:34-35、ScanSheet.swift:65-66、QuotaView.swift 扫码导入粘贴框） | **两个修饰符整段删除**（三个文件、UI 与 Quota 两模块都要删） | macOS 的 TextField 没有这两个成员（swiftc -typecheck 实测 no member）；`.autocorrectionDisabled()` 保留可用（实测可编译） |

## ④ macOS 窗口形态决策（定死）

**单窗口 `WindowGroup` + `NavigationStack(path:)` 列表→详情推入**（与 iOS RootView 同构，
不采用 NavigationSplitView：split 会引入 selection 状态与三栏形态，超出移植范围；
NavigationStack 让 Router、replaceTop、冷启动直达逻辑零改动）。

对 Router 的实现要求（UI 模块落地，签名见第 ① 节）：

- `@Published var path: NavigationPath()`，RootView 以 `NavigationStack(path: $router.path)` 持有，
  `.environmentObject(router)` 注入，WebScreen `@EnvironmentObject` 取用；
- `open(_:)` = `path.append(id)`；`replaceTop(with:)` = 栈空则 append，否则 removeLast + append
  （照抄 ios/ZCodeRemote/RootView.swift:5-22）；
- 详情目的地：`.navigationDestination(for: UUID.self) { WebScreen(instanceID: $0) }`；
- 冷启动直达逻辑照搬 iOS（RootView `.task`：`store.instances.lastOpened ?? store.instances.only` →
  `router.open`；`-ZCODE_AUTOPEN_URL <url>` 启动参数通道保留，CI/调试用）。

## ⑤ 桌面形态策略

mac **恒以桌面形态加载**：WebScreen 创建 WKWebView 时无条件
`customUserAgent = Urls.desktopUserAgent`（WKWebView 在 macOS 默认就是桌面形态，
iOS 的 `preferredContentMode` 是 iOS-only 概念，mac 上不设置）。

`Instance.desktopMode` 字段**只为兼容既有 JSON 保留**：

- Core 已保留该字段，解码旧 JSON（iOS 导出/共享的 instances.json）不丢数据；
- Web 模块**禁止**读取 `Instance.desktopMode` 决定 UA 或任何行为；
- UI 模块编辑页默认隐藏「以桌面版网页加载」开关，保存时把原值原样写回；
  新建实例一律写 `desktopMode: true`。
