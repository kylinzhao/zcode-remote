# T6 构建与验证方式（decision）

## Question

APK 在哪构建、如何签名、如何证明「可安装且可用」？

## MECE 备选

- a) 本机构建：工具链已就绪（JDK17/Gradle 8.9/SDK 34/arm64 模拟器镜像），分钟级反馈 — ✓
- b) GitHub Actions：需远端仓库与推送授权（外发动作），环网时间长 — 否
- c) 仅交付源码：不满足「可安装」目标 — 否

## Resolution（closed 2026-09-21，验收全过）

选 **a)**。签名用项目内自建 keystore（密码记录于 README，用户可自行更换以保证后续升级安装）。
验收结果（模拟器 android-34 google_apis arm64，Pixel 6 profile，Android 14 实测）：

1. ✅ `assembleRelease` 成功（647KB），`apksigner verify` 通过；
2. ✅ adb 安装成功、启动无崩溃；
3. ✅ 深链接添加实例（真实扫码 URL）→ 名称自动预填 `MacBook-Air-57` → 列表出现；
4. ✅ 打开实例 → **真实 zcode.z.ai 远程页加载成功**：显示「已连接到当前桌面窗口，
   16 个工作区 · 203 个任务」及真实任务列表（截图 screens/03_remote_loaded.png）；
5. ✅ 错误场景（127.0.0.1 拒连）→ 中文错误页 + 重试按钮（截图 screens/05_error_page.png）；
6. ✅ 附加：非导出 Activity 被 adb 直接启动正确拒绝（安全 posture 符合预期）。

注：因 T8 环境故障，实现为纯平台 UI；验证标准不受影响。
