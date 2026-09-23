# wayfinder:map — Android ZCode 远程客户端

> 本地 markdown tracker（无远端 issue tracker）。用户指令覆盖 wayfinder 默认「只规划不执行」：
> 本 effort 的执行（实现/构建/验证）一并纳入本会话完成。

## Destination

一个可直接安装在 Android 手机上的 ZCode 客户端 APK：内嵌 WebView 加载 ZCode 桌面端「远程访问」生成的网页，支持管理多个实例（家里电脑、公司电脑各一个），并在本机模拟器端到端验证通过、附两台电脑的接入文档。

## Notes

- 领域：Android 客户端（Kotlin + WebView 壳）× ZCode 桌面端远程访问能力。
- 本机工具链事实：JDK 17（Homebrew）、Gradle 8.9（~/gradle）、Android SDK（~/android-sdk：platform 34、build-tools 34.0.0、arm64 模拟器镜像 android-34/google_apis）。`ANDROID_HOME` 未设 → 写入 local.properties。
- ZCode 桌面端为 Electron 应用（/Applications/ZCode.app，v3.14.0，dev.zcode.app）。

## Decisions so far

- [T1 ZCode 远程访问形态是什么](tickets/T1-zcode-remote-access.md) — 桌面端内置「远程访问」，扫码得到 zcode.z.ai 云中继页面 URL，URL 即凭证，无需 VPN/端口转发
- [T2 客户端壳技术选型](tickets/T2-shell-technology.md) — 原生 Kotlin + WebView（单 Activity 页面族），不用 Flutter/RN/TWA
- [T3 网络路径与部署形态](tickets/T3-network-path.md) — 依赖云中继，App 保持「任意 https URL」通用；不内置 VPN 逻辑
- [T4 多实例模型与交互](tickets/T4-instance-model.md) — 实例列表 → 点击进全屏 WebView；同一时刻仅一个活动 WebView；本地 JSON 存储
- [T5 安全策略](tickets/T5-security.md) — 仅允许 https；凭证存 App 私有目录；SSL 错误一律不放行并给中文错误页；URL 不打日志
- [T6 构建与验证方式](tickets/T6-build-and-verify.md) — 本机工具链 assembleRelease + 项目内 keystore 签名 + 模拟器真机级端到端验证（含真实远程页加载截图）
- [T7 交付物清单](tickets/T7-deliverables.md) — APK + 签名 keystore + README（两台电脑接入指南）+ 本地图
- [T8 本机 AGP 资源管线故障与绕行](tickets/T8-build-environment-fog.md) — AAR 库资源在本机链接期确定性丢失；改为零 AndroidX 依赖的纯平台 UI 实现，构建成功
- [T9 App 内扫码绑定](tickets/T9-in-app-scanning.md) — 主入口改为应用内扫码（zxing core JAR + camera2 自研壳），扫完自动存实例并打开；粘贴兜底
- [T10 iOS 版](tickets/T10-ios-version.md) — SwiftUI + WKWebView + DataScanner；iPad 桌面形态为每实例开关（desktop UA + preferredContentMode）；无 Xcode，CI(macos-15) 构建验证
- [T11 单实例直达与页面内添加](tickets/T11-single-instance-autopen.md) — 仅一个实例时进 App 直开；页面菜单「添加新实例」clearTop/replaceTop 保证返回栈 列表→页面
- [T12 页面状态保持与冷启动直达](tickets/T12-page-state-restore.md) — 冷启动按 lastOpenedAt 直达上次实例；热唤起（ROM 清栈）按 LastPage 标记恢复退出前页面；savedInstanceState 区分系统重建

## Not yet specified

- T8 遗留 fog：本机 AGP merge→link 资源丢失的根因（交叉验证方案见 T8 遗留节）

- ZCode 桌面端远程链接的有效期/吊销策略（官方未文档化，观察项；不影响 v1 交付——失效后重新扫码添加即可）
- 远程页面通知能力（若未来 H5 提供推送桥，可考虑 Android 通知桥接）

## Out of scope

- iOS 版本（用户未要求）
- 修改 ZCode 桌面端 / 其远程协议（只做消费方）
- 自建中继服务器或局域网穿透功能（云中继已满足）
