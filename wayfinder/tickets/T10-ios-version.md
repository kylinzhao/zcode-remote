# T10 iOS 版（SwiftUI）与 iPad 桌面形态（decision + task）

## Question

Android 版完成后开发 iOS 版：功能对齐（应用内扫码绑定 + 多实例 + 安全 WebView），
iPad 需支持 PC 形式的 web 访问。本机无 Xcode 如何交付与验证？

## 决策

1. **技术栈**：SwiftUI（iOS 16+）+ WKWebView + VisionKit `DataScannerViewController`（扫码）。
   不引入 WebView 库（SwiftUI WebView 尚无系统组件，WKWebView representable 是标准做法）。
2. **iPad 桌面形态**：`WKWebpagePreferences.preferredContentMode = .desktop` +
   macOS Safari UA（`Urls.desktopUserAgent`）。实测（curl 双 UA）页面 shell 与 UA 无关
   （SPA 客户端渲染），桌面布局由页面按 viewport 自适应——iPad 宽屏 + desktop 模式即 PC 形式。
   该能力做成**每实例开关**（"以桌面版网页加载"），iPad 默认开，iPhone 可手动开；
   支持同一 App 开多窗口（SwiftUI WindowGroup 默认）实现两台电脑并排访问。
3. **验证方式（本机无 Xcode 的替代）**：GitHub Actions `macos-15` runner（自带 Xcode 16）：
   xcodegen 生成工程 → `xcodebuild` 模拟器构建 → simctl 启动 iPhone/iPad 模拟器 →
   `-ZCODE_AUTOPEN_URL` 启动参数自动添加并打开 `https://httpbin.org/user-agent`（UA 回显页）→
   截图为 artifact，验证 iPad 的 desktop UA 生效与 WebView 主链路。
   扫码依赖真机相机，模拟器不可验证（DataScanner.isAvailable=false 时 UI 自动降级为粘贴）。
4. **真机安装**：交付源码 + project.yml，用户装 Xcode 后 `brew install xcodegen && cd ios && xcodegen`
   打开工程选自己的 Team 即可免费签名安装（7 天有效期）。

## 状态（closed 2026-09-21，CI 验证全过）

- 代码：ios/（xcodegen 工程 + 7 个 Swift 文件）；CI：.github/workflows/ios-build.yml
- CI 5 轮迭代后绿（编译错误：@discardableResult 拼写、RecognizedItem 类型与
  payloadStringValue 属性名、customUserAgent 归属 WKWebView、confirmingDelete 作用域、
  ?? 优先级——均为无 Xcode 环境下静态自查的预期偏差）
- 模拟器实测（artifact 截图）：
  - iPhone：空列表渲染正常；WebView 加载 httpbin.org/user-agent 回显 **iPhone UA**
    （移动形态正确）、导航栏双行标题正常；
  - iPad：列表正常；WebView 回显 **macOS Safari UA（Version/17.4）** →
    桌面形态（PC 形式）生效（截图 04_ipad_desktop_ua.png）；
  - 首轮 iPad 黑屏为模拟器 boot 时机问题（分步截图后消失），非应用问题；
  - 扫码（DataScanner）依赖真机相机，模拟器自动降级为粘贴，待真机人工验收。
