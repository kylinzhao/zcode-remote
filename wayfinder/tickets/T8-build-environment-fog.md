# T8 本机 AGP 资源管线故障与绕行（task/research）

## Question

本机构建 Android 工程时，`processReleaseResources` 对**任何 AAR 库资源**确定性报
`attribute auto:X not found`（appcompat/material 全部属性不可见），如何交付可安装 APK？

## 排查过程（关键证据）

1. 官方产物核验：material-1.12.0 / appcompat-1.7.0 的 AAR 均与 dl.google.com 官方 SHA1 一致
   （亦与阿里云镜像一致），文件本体完好；
2. 手工 `aapt2 compile+link` 一次性模式完全正常，AGP 管线内确定性失败；
3. AGP 8.5.2 → 8.7.3 升级、clean、非沙箱运行、清理 daemon，均同样失败（确定性、跨版本）；
4. 最小 appcompat 应用（/tmp/miniapp）同样无法通过资源链接（另撞上与本案无关的
   kotlin-stdlib 重复类问题）；
5. 合并产物中库 value 翻译（values-af 等 120+ 文件）存在，但库的 attr/drawable 符号
   在链接期不可见——故障定位于 AGP「merge → link」之间的资源传递环节，具体机制未能
   在预算内查明（fog，已记录）。

## Resolution（2026-09-21）

**改为零 AndroidX/Material 依赖实现**：全部 UI 用 `android.*` 平台控件
（ListView/Switch/EditText/ProgressBar/PopupMenu/AlertDialog/自绘 drawable），
构建期链接输入仅剩应用自身资源 + android.jar，绕开故障管线。

- 验证：`assembleRelease` 成功，`apksigner verify` 通过，APK 647KB；
- 代价：放弃 M3 组件观感，用自绘 drawable 近似（视觉验收见模拟器截图）；
- 影响面：仅 UI 层；WebView/存储/安全策略逻辑不变。

## 遗留 fog（给未来会话）

- 若日后在本机需要 androidx 库：优先试**全新用户目录**（`GRADLE_USER_HOME=/tmp/gradle-home`）
  与另一台机器交叉验证，以区分「本机 SDK 布局/杀毒/Spotlight 干扰」与「AGP 通用故障」；
- 官方 issue tracker 上以 `LinkApplicationAndroidResourcesTask` + `attribute not found`
  检索新版本已知问题。
