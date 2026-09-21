# T5 安全策略（decision）

## Question

URL 中内嵌凭证（hash）、加载远程页面时的证书与明文策略如何定？

## MECE 备选

- a) 每实例「信任自签名证书」开关：为局域网自建服务设计；云中继是正规 CA 证书，用不上，且扩大攻击面 — 否
- b) SSL 错误一律放行：绝对不行 — 否
- c) **仅 https + 系统 CA + SSL 错误一律中止**，凭证存 App 私有 SharedPreferences，URL 不进日志 — ✓

## Resolution（closed 2026-09-21）

选 **c)**：

- 添加实例时强制校验 `https://`（明文直接拒绝）；
- `onReceivedSslError` 一律 `cancel` 并落中文错误页（防降级/中间人）；
- 添加时对粘贴内容裁剪空白/控制字符（扫码复制常带换行）；
- WebView 不开启文件访问（`allowFileAccess=false`）、禁 geolocation/摄像头等权限弹窗授权面；
- `Log` 不输出完整 URL（内含 hash 凭证）。
