# T4 多实例模型与交互（decision）

## Question

「家里电脑 / 公司电脑」多个实例的数据模型与切换交互如何设计？

## MECE 备选

- a) 实例列表页 → 点击进全屏 WebView，返回回列表 — 单活动 WebView，内存友好、语义清晰
- b) 底部 Tab 常驻多 WebView — 同时保活 N 个 WebView（每个几十 MB）+ 状态同步复杂 — 否
- c) WebView 内叠抽屉切换 — 复杂度同 b，且遮挡远程页面 UI — 否

## Resolution（closed 2026-09-21）

选 **a)**。

- 数据模型：`Instance { id, name, url, keepScreenOn, createdAt, lastOpenedAt }`，SharedPreferences 存 JSON 数组（量级 ≤ 个位数，无需 Room）。
- 添加实例：粘贴/深链接带入 URL；自动从 URL `name` 查询参数预填实例名（如 `MacBook-Air-57.local` → `MacBook-Air-57`）。
- WebView 页顶栏 = 实例名；溢出菜单：刷新 / 在浏览器打开 / 复制链接 / 编辑 / 删除。
- 系统返回键 = `canGoBack ? goBack : 回列表`。
- 深链接增强：注册 `https://zcode.z.ai/remote/*` 的 VIEW intent-filter（出「打开方式」选择器）+
  系统分享（ACTION_SEND）接收 —— 扫码后可一键进 App 添加。
