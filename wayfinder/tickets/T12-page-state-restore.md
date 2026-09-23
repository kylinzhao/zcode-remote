# T12 页面状态保持与冷启动直达（decision + task）

## Question

两个症状：(1) App 退到后台再回前台，回到列表页而不是退出前的页面；
(2) 冷启动落在列表页，要求直接进入上一次选择的电脑页面，不再选一次主机。

## 根因

代码里没有任何"回前台跳回列表"的逻辑，两条症状是三类系统行为造成的：

1. **部分 ROM 启动器以启动 Intent 直达 singleTask 根**：`MainActivity` 是
   `launchMode="singleTask"`，被再次以 ACTION_MAIN 唤起时系统会**清掉上方页面**
   （模拟器上 `am start -a MAIN -c LAUNCHER` 即可复现，原生 Pixel 启动器不清、
   但国产 ROM 常见此语义）→ 用户看到列表。**这是症状 (1) 在进程未死时的真因。**
2. **后台进程被系统回收**：再点图标实为冷启动，Activity 栈/导航栈全丢 → 列表。
3. 原有"单实例自动打开"只覆盖 `instances.count == 1`，多实例时永远落列表 → 症状 (2)。

## Resolution（2026-09-23，Android 模拟器已验证）

统一为"恢复到上一次打开的实例页面"，按进入路径分三条：

### Android

- **冷启动**（`onCreate` 且 `savedInstanceState == null`，深链接/分享优先）：
  `restoreLastPage()` 打开 `lastOpenedAt` 最近的实例（每次打开都更新、已持久化）；
  全部实例从未打开过时回退旧的"仅单实例直达"。`savedInstanceState != null`
  说明系统在重建返回栈（WebActivity 会自行恢复），不介入——顺带修掉重建时
  重复消化原始深链接 intent 的问题。进程级 `autoOpened` 标记防止从页面返回
  列表后被反复拉回。
- **热唤起**（`onNewIntent` 收到 ACTION_MAIN 或 null action）：部分 ROM 会清掉
  singleTask 根上方的页面。新增 `LastPage` 标记（settings prefs）：
  `MainActivity.onPause` 写 "list"，`WebActivity` 在 onResume/onPause/onNewIntent
  切换时写 "page:<id>"——退后台时最后一次写入即"退出前所在页面"。
  热唤起时读到 "page:<id>" 就重开该实例；读到 "list"（用户主动退回列表后离开）
  则停在列表。**不用 `lastOpenedAt` 做热恢复**：它无法区分"停在页面"与
  "已主动退回列表"。
- **进程未死 + 原生启动器**：系统保留任务栈，无需干预。

### iOS

- 进程未杀的挂起/恢复：SwiftUI NavigationStack 在内存中，天然保持。
- 后台被杀后冷启动：`RootView.task`（每次冷启动执行，挂起恢复不会重进）里
  `store.instances.lastOpened ?? store.instances.only` 直达上次实例，
  `didAutoOpen` 防重复。

### 行为约定

- 冷启动**总是**直达最近使用的实例（用户明确要求"别再选一次主机"），
  即使上次退出时停在列表——多按一次返回即回列表。
- 热唤起严格恢复"退出前所在页面"，主动停在列表就不打扰。
- 页面内 Web 级状态（滚动位置等）不跨进程恢复，重新加载远程页
  （URL 含 sid/hash，会话在服务端续起）。

## 验证

- Android：`scripts/t12_restore_e2e.sh`（API 34 模拟器，无头）9 个场景全过：
  空列表冷启动；深链接添加「甲」→ 打开甲；添加「乙」→ 打开乙；
  HOME→图标再进（清栈语义）恢复乙；`am kill`→再进恢复乙；
  **force-stop（等价激进 ROM）冷启动直达乙**；列表态 force-stop 冷启动仍直达乙；
  `always_finish_activities=1` 重建栈仍在乙页面。
  截图 `screens/t12_*.png`（AI 视觉复核标题=乙电脑/甲电脑）；
  `gradlew test assembleRelease` 通过，dist APK 已更新。
- iOS：本机无 Xcode，CI（macos-15）验证——编译 + 模拟器冒烟新增
  `02b_iphone_restore.png`：`-ZCODE_AUTOPEN_URL` 打开 httpbin 后，
  杀进程重启（不带参数）应直达该实例页而非列表。

## 已知边界

- 扫码/编辑页停留时被清栈：热恢复会落到之前的实例页（扫码上下文丢失，可接受）。
- `am start -n`（无 action）也按启动器唤起处理，仅影响 adb 调试语义。
