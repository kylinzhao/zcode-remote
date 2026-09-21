# ZCode Remote — Android & iOS 客户端

一个可直接安装的移动客户端：内嵌 WebView 打开电脑端 ZCode 的「远程访问」页面，
并支持管理多个实例 —— 家里电脑、公司电脑各一个，一键切换。

- **Android**：见下文「安装」「从源码构建」，APK 在 Release 页直接下载；
- **iOS / iPadOS**：见文末「iOS 版」，应用内扫码 + 多实例，iPad 以桌面形态（PC 形式）加载。

**工作原理**：ZCode 桌面端（v3.14+）内置「远程访问」，会生成一个经 `zcode.z.ai` 云中继的
扫码网址（`https://zcode.z.ai/remote/v4?sid=…&hash=…&mid=…&name=…`）。手机打开该网址
即可在浏览器里操控那台电脑上的 ZCode。本客户端把这个「网址」变成一个可管理的**实例**：
安全存储、一键打开、随时切换，并补充了深链接接入、屏幕常亮、中文错误页等体验。

```
手机 App（WebView 壳） ──HTTPS──> zcode.z.ai 云中继 <──> 电脑端 ZCode 桌面应用
                                       ↑ 不需要 VPN / 端口转发 / 自签证书
```

## 安装

1. 把 `dist/ZCodeRemote-v1.0.0-release.apk` 传到手机（微信文件传输助手 / AirAndroid / 数据线均可）；
2. 点击安装（需允许「安装未知来源应用」）；
3. 打开 ZCode Remote，点右下角「＋」添加第一台电脑。

要求：Android 8.0（API 26）及以上。

## 添加实例（每台电脑做一次）

1. 在**电脑端 ZCode** 打开「远程访问」，屏幕上会出现绑定二维码；
2. 手机打开 ZCode Remote，点右上角「＋」，**对准电脑屏幕扫码**即可——
   App 会自动识别链接、按电脑名命名实例并保存、直接打开该电脑的远程页面；
   （同一链接重复扫描不会产生重复实例）
3. 没法扫码时，扫码页底部有「手动粘贴链接」兜底；也可以扫后在浏览器打开再
   「分享 → 添加到 ZCode Remote」，或系统弹出「打开方式」时直接选 ZCode Remote；
4. 只接受 `https://` 链接；网址内含凭证，粘贴前留意来源。

之后在列表里点击实例即可打开对应电脑；远程链接失效（电脑端重启/重新生成）时，
重新扫一次码即可。

## 两台电脑的注意事项

- **家里电脑**：ZCode 桌面应用保持运行、远程访问开启即可；手机在任何网络下都能连
  （走云中继，不依赖同一 WiFi）。
- **公司电脑**：同上。若公司网络限制访问 `zcode.z.ai`，需确认电脑端能连上 ZCode 云服务；
  手机侧无特殊要求。
- 实例的网址内含访问凭证（`hash` 参数），只保存在手机 App 私有目录中，请勿把链接发给他人
  ——拿到链接的人可以操控你的 ZCode。

## 功能

- 多实例管理：列表展示（主机名 · 最近打开时间）、长按菜单编辑/删除/复制链接
- **应用内扫码绑定**：点「＋」直接扫电脑端二维码，识别后自动保存并打开（zxing core 解码，
  相机权限仅用于扫码）；扫码页带手电筒与「手动粘贴链接」兜底
- 深链接接入：`zcode.z.ai/remote/*` 的链接可直接选择本应用打开；支持系统分享接收
- WebView：JavaScript/DOM 存储、缩放、返回键映射网页历史、外部链接（mailto/tel 等）交给系统
- 打开实例时可开启「保持屏幕常亮」（盯长时间任务时有用）
- 深色模式跟随系统；加载进度条；断网/证书异常时显示中文错误页并可一键重试

## 安全设计

- 仅接受 `https://` 实例；证书校验失败一律**阻止加载**（不提供「继续访问」）
- 禁用 WebView 文件访问；明文 HTTP 被拒绝
- 实例数据保存在应用私有 SharedPreferences，不进入日志；随 Android 系统自动备份

## 从源码构建

```bash
# 依赖：JDK 17、Android SDK（platform 34 + build-tools 34）
# local.properties 里已写 sdk.dir（按需修改）
./gradlew assembleRelease
# 产物：app/build/outputs/apk/release/app-release.apk
```

零第三方依赖：UI 全部基于 `android.*` 平台控件实现（不引入 AndroidX/Material，
构建仅需 Kotlin 标准库与 zxing core 纯 Java 解码库），APK 约 880KB。

签名密钥**不入库**：本机若存在 `keystore/release.keystore` 则用其正式签名；
新克隆的环境自动回退 debug 签名（同样可直接安装）。要发自己的正式版：

```bash
keytool -genkeypair -keystore keystore/release.keystore -alias zcode-remote \
  -keyalg RSA -keysize 2048 -validity 10950
# 并同步修改 app/build.gradle 中 signingConfigs.release 的口令与 alias
```

注意：换签名密钥后需卸载重装（Android 校验签名一致性）。

## 工程结构

```
app/src/main/java/dev/zcode/remote/
  MainActivity.kt          实例列表 + 深链接/分享接入
  InstanceEditActivity.kt  添加/编辑实例
  WebActivity.kt           WebView 壳（错误页/菜单/常亮）
  Instances.kt             实例模型与本地存储、URL 清洗
wayfinder/                 决策地图（技术选型与验证记录）
```

## iOS 版（iPhone / iPad）

SwiftUI 原生实现，功能与 Android 版对齐：

- **应用内扫码绑定**：点「＋」用系统数据扫描器（VisionKit DataScanner）扫电脑端二维码，
  自动按电脑名保存实例并打开；粘贴兜底始终可用；
- **多实例管理**：列表按最近打开排序，长按编辑/复制/删除，按链接去重；
- **iPad 桌面形态**：iPad 默认以 **PC 形式**加载远程页（macOS Safari UA + desktop content
  mode，页面自动呈现桌面布局），并支持多窗口并排访问两台电脑；
  该能力同时做成每实例开关（"以桌面版网页加载"），iPhone 需要时也可打开；
- **安全**：仅 https；WKWebView 不提供证书绕过；实例数据存 App 沙盒 JSON；
  屏幕常亮开关；断连中文错误页 + 重试。

### 构建（需要一台装有 Xcode 的 Mac）

```bash
brew install xcodegen
cd ios && xcodegen
open ZCodeRemote.xcodeproj
# 在 Signing & Capabilities 里选择你的 Apple ID Team（免费个人账号即可）
# 连接 iPhone/iPad，选中设备后 Run
```

免费签名 7 天有效，到期重跑一次；持续使用建议加入 99 美元/年的开发者计划。
仓库 CI（`ios-build` workflow）会在每次 iOS 代码变更时自动构建并生成模拟器截图（Artifacts）。
