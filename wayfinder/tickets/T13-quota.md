# T13 账号额度（多账号，移动端版 zcode-switch 额度能力）

## Question

App 内能否看到各个 GLM/Coding Plan 账号的额度（参考桌面端 zcode-switch / zsv）？
凭据怎么安全弄到手机、查询走什么通道？

## 调研结论（2026-09-29，本机实测）

- 额度就是「公网 HTTPS 接口 + 账号凭据」，手机可直连，不需要电脑在线：
  - 主通道：coding-plan API Key → `open.bigmodel.cn /api/monitor/usage/quota/limit`
    （个人直查；企业席位 `?type=2` + `bigmodel-organization`/`bigmodel-project` 头），
    业务拒绝或网络失败自动换 `api.z.ai` 同路径；
  - 附带 `/api/biz/subscription/list`（套餐名/到期）与
    `/api/biz/customer-package-reset/list`（重置卡），失败静默；
  - 兜底：JWT → `zcode.z.ai /api/v1/zcode-plan/billing/balance`。
  - 本机用导出的三把真实 key 实测全通（个人 Pro/Lite、企业 Max 席位）。
- 凭据来源：`~/.zcode-switch/accounts/*.json`（zsv 账号库，含全部已存账号）或当前
  `~/.zcode/v2/credentials.json`；`enc:v1` 是 AES-256-GCM、密钥
  `SHA256("zcode-credential-fallback:{platform}:{home}:{username}")`，纯算法可本地解。
- zsv 参考实现：`~/guazi/work/zcode-switch/review-src`（quota.rs/store.rs/zcrypto.rs，
  quota-plus 分支）；通道策略与解析键名与其对齐。

## Decisions

1. **凭据导入 = 桌面导出脚本 + 扫码**（复用实例扫码基建的交互模型）：
   `scripts/quota-qr.py` 本地解密凭据生成二维码页面（qrcode.js 内嵌，无新增运行时依赖），
   载荷 `{"v":1,"type":"zcode-remote-accounts","accounts":[{"n","k","jwt?","team?"}]}`，
   >1800 字节自动拆成每账号一码；同名账号覆盖凭据（对应实例按 URL 去重语义）。
   手动粘贴 JSON / 手动填 Key 双兜底。
2. **查询在手机本地直连**，不经过电脑、不经过中继；HttpURLConnection / URLSession
   各自实现（仓库无网络库依赖，Android 遵守 T8 零 AAR 红线）。
3. **存储沿用实例的安全模型**：SharedPreferences / Application Support JSON 明文存
   私有目录（与 T5 一致：URL 内含 hash 同级别凭证；Key 为查询权限，风险更低），
   不进日志；二维码页面提示用完即关。
4. **UI = 新增原生页面**（Android `QuotaActivity` 平台控件 ListView + 动态额度条；
   iOS `QuotaView` insetGrouped List + ProgressView），入口在主页标题栏「📊」
   （Android）/工具条「chart.bar」（iOS）；进度条 ≥75% 琥珀、≥90% 红。
5. **刷新策略**：手动（全部/单账号）+ 打开页面对「从未刷新过」的账号自动查一次；
   不做后台定时（后续可挂 ntfy/WorkManager，本轮不做）。

## 状态（closed 2026-09-29，模拟器真机级验证通过）

- 桌面导出脚本对本机真实账号库实测：导出 3 账号（含席位 key + 组织头），载荷 385B 单码。
- 模拟器（Pixel 6 / API 34）安装 debug 包、灌入真实凭据 → 额度页实时拉取并正确渲染：
  Max/Pro/Lite 徽章、5h/周额度条与用量、重置卡张数、到期时间、93% 红色警示全部正确
  （screens/quota_real_2.png）。
- Android `assembleDebug`/`assembleRelease` 通过；iOS 无本机 Xcode，`swiftc -parse` 通过，
  构建验证走 CI（ios-build.yml）。
