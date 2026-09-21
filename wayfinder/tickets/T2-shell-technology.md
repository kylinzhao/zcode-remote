# T2 客户端壳技术选型（decision）

## Question

Android 客户端用什么技术实现「内嵌 zcode 远程网页 + 多实例管理」？

## MECE 备选

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| a) 原生 Kotlin + WebView | 本机工具链现成（SDK 34 + Gradle 8.9）；APK 极小；深链接/分享接收/菜单等系统能力一等公民；风险最低 | UI 需手写（本 App 仅两屏，成本低） |
| b) Flutter + webview_flutter | UI 漂亮、未来跨 iOS | 需下载完整 Flutter SDK（GB 级）；对「两个页面的壳」严重过度设计 |
| c) React Native / Capacitor | 前端栈熟悉 | 引入 JS 工具链与桥接层，故障面变大；体积大 |
| d) PWA / TWA（浏览器直接装） | 零代码 | 无法做实例管理器；依赖 zcode 页面出 manifest（实测无）；拿不到深度链接/凭证管理控制权 |

## Resolution（closed 2026-09-21）

选 **a) 原生 Kotlin + WebView**。理由：交付目标只有 Android、只有两个界面、需精确控制
深链接接收/URL 校验/错误页/返回键语义——原生壳全部最小成本满足，且是唯一「今天就能在本机出 APK」的路径。
