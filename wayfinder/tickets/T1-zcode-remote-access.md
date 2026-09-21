# T1 ZCode 远程访问形态是什么（research）

## Question

ZCode 桌面端是否存在「远程访问」网页能力？若存在，其入口、协议、鉴权形态是什么？手机如何访问？

## Resolution（closed 2026-09-21）

**存在，且为云中继形态。** 证据：

1. 对 `/Applications/ZCode.app/Contents/Resources/app.asar`（312MB）做字符串分析：
   - 无「局域网/扫码/远程访问」本地 server 类 UI 文案 → 排除局域网监听形态；
   - 存在 `zcode://` deep link（workspace/open）、`ZCODE_BASE_URL`、`ZCODE_REMOTE_WORKSPACE_DISCONNECTED` 等云通道痕迹；
   - qrcode 相关字符串 22 处 → 存在二维码生成能力。
2. 用户提供真实扫码 URL 实证（已 curl 验证 200）：
   `https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…&mid=<machine-id>&name=<主机名>&app_version=3.14.0`
   - 页面：`<title>ZCode</title>`，React SPA（react/react-dom/lucide），深色主题（theme-color #161616），
     viewport 移动端适配，资源按版本路径 `/remote/v4/3.14.0/assets/*` 发布；
   - 鉴权：URL 查询参数自带 `sid` + `hash`（凭证在 URL 里，无独立登录流程）；
   - CDN 头（ESA/acw_tc）为阿里云边缘，标准系统 CA 证书即可。

**结论**：手机访问 = 桌面端「远程访问」扫码 → 打开云中继 URL。Android 客户端只需安全地管理并加载这些 URL。
