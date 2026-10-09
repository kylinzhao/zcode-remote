# T14 macOS 版（公司 Mac 遥控家里电脑的 ZCode）

## Question

手机之外，公司发的电脑是 Mac：能否做一个 macOS 版客户端，在公司 Mac 上遥控家里电脑的
ZCode？本机只有 Command Line Tools（CLT）如何构建、签名与分发？桌面形态下
「扫码绑定」「任务提醒」「桌面网页形态」这些移动端能力如何对应？

## 背景

- 本机只装了 CLT（`swiftc` / `codesign` 可用，无 xcodebuild / 模拟器 / 完整 SDK 工具链），
  iOS 版「用户自己装 Xcode + xcodegen」的交付路径在本机走不通，也不打算为此装 Xcode。
- WKWebView、UserNotifications、AVFoundation（含 AVCaptureSession）在 macOS 均原生可编译，
  差异集中在 UIKit→AppKit 的 UI 层与桌面使用习惯（详见 mac/CONTRACT.md ③ 移植对照表）。
- mac/Sources/ 按 Core/UI/Web/Quota 四模块并行开发，接口契约见 mac/CONTRACT.md；
  合编为单一编译目标，模块边界靠契约约定。

## 决策

1. **纯 swiftc 零 Xcode 构建**：`mac/build-mac.sh` 把 `mac/Sources/` 下全部 `.swift`
   用 `swiftc -swift-version 5` 编译为单一目标（无 .xcodeproj / xcodegen / SPM），
   拷入 `mac/Info.plist` 组装 `.app`。依赖仅 CLT，最低系统 macOS 14.0。
   本机实测：13 个源文件编译通过，arm64 二进制约 1.8MB。
2. **ad-hoc 签名本地分发**：`codesign --force --sign -`，不申请 Developer ID、不做公证。
   本机构建 `open` 即可运行；把 `.app` 拷给其他 Mac 时由 Gatekeeper
   「系统设置 → 隐私与安全性 → 仍要打开」放行。App 不上架、无自动更新，
   个人/团队内部分发足够，换取零证书与零账号成本（对比 iOS 免费签名 7 天过期）。
3. **无相机扫码 → 粘贴 + 二维码截图解码（CoreImage）**：桌面没有「举着设备对准电脑屏幕」
   的动作，实例添加/换链接按无相机设计——粘贴远程链接为主，二维码截图
   （拖入 / ⌘V / 选图 / 读剪贴板）用 `CIDetector(.qr)` 解码兜底
   （mac/Sources/UI/QRImageSupport.swift；截图走 TIFF 取原始像素，避免 Retina 降采样）。
   额度页凭据导入保留相机扫码（ScannerBox：AVCaptureSession + NSViewRepresentable
   自建，mac 无 VisionKit DataScanner；无摄像头时自动退化为粘贴/截图导入）。
4. **UserNotifications 任务提醒**：通道一（注入检测脚本与 iOS/Android 副本逐字节一致，
   流量形态判定）+ `UNUserNotificationCenter` 系统通知，**Dock 角标 = 未读实例数**
   （iOS 桌面角标的 mac 对应物），打开实例即消化；异常中断单独文案。
   ntfy 推送（通道二）未纳入本轮移植——CONTRACT 四模块范围里没有推送，
   mac App 不像手机会被系统频繁回收，通道一在 App 运行期间已覆盖。
5. **恒桌面形态加载**：WKWebView 在 macOS 本就是桌面形态，创建时无条件
   `customUserAgent = Urls.desktopUserAgent`，**不读** `Instance.desktopMode`；
   该字段仅为兼容 iOS 共享的 instances.json 保留（新建实例写 true，编辑页隐藏
   「以桌面版网页加载」开关、保存时原值写回，CONTRACT ⑤）。
6. 其他 mac 适配（CONTRACT ③，均为 swiftc -typecheck 实测）：无「保持屏幕常亮」开关
   （Mac 接电源，休眠归系统设置；`keepScreenOn` 字段保留、原值写回）；无下拉刷新
   （`UIRefreshControl` 无对应物，保留工具菜单「刷新」，注入脚本的下拉探测段无消费者但
   逐字节保留以维持三端副本一致）；`.navigation`/`.principal` placement 布局无效，改
   `.automatic` + 窗口标题/副标题；`listStyle(.inset)`、`Color(nsColor:)` 等对应替换。

## 状态（2026-10-09，本机构建通过；CI 待首跑）

- `bash mac/build-mac.sh` 本机（CLT-only）实测通过：`mac/build/ZCodeRemote.app`
  ad-hoc 签名（`codesign -dv` 确认 Signature=adhoc、arm64）。
- CI：`.github/workflows/mac-build.yml`（macos-15 runner，构建 + 打 zip 上传 artifact），
  随本次提交首跑验证。
- `mac/build/` 产物目录已被根 .gitignore 既有 `build/` 规则覆盖
  （`git check-ignore -v` 实测命中 `.gitignore:6`），无需新增忽略项。
- 相机扫码（ScannerBox）依赖真机摄像头，本机未做人工验收；无摄像头路径
  （截图/粘贴导入）为桌面主路径，已随构建验证可编译。
