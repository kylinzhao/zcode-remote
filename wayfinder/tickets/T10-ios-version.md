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

## 状态

- 代码：ios/（xcodegen 工程 + 7 个 Swift 文件）；CI：.github/workflows/ios-build.yml
- 待 CI 跑绿（编译 + 双模拟器截图）
