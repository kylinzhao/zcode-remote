# T11 单实例直达与页面内添加（decision + task）

## Question

仅绑定一个实例时，进入 App 应直接打开该页面；页面内右上角菜单提供「添加新实例」；
左上返回直达列表。双端如何实现并保证返回栈干净？

## Resolution（2026-09-22，双端已验证）

1. **单实例自动打开**：
   - Android：`MainActivity.onCreate` 进程级一次性（companion 标记）→ `openInstance`；
     避免旋转/从页面返回后被反复拉回。模拟器 30 秒 Resumed 稳定性测试通过。
   - iOS：`RootView.task` + `didAutoOpen` 状态（每窗口一次）；iPad 多窗口各自自动打开（合理）。
2. **页面内「添加新实例」**：Web 页右上角菜单首项（Android PopupMenu / iOS Menu→ScanSheet）。
3. **添加后返回栈干净**：
   - Android：WebActivity `launchMode=singleTop` + 启动 Scan 时带 `clearTop` extra →
     扫码/粘贴保存后以 `FLAG_ACTIVITY_CLEAR_TOP|SINGLE_TOP` 启动 WebActivity →
     同一实例 onNewIntent 切换 URL。返回栈恒为 列表→页面。
     模拟器实测：页面内添加 example.com 后同页切换、无旧页残留。
   - iOS：Router.replaceTop（removeLast+append）替换栈顶为新的 WebScreen。
4. **左上返回**：两端返回按钮均直接退出页面回列表（Android finish / iOS pop）；
   Android 系统 BACK 保留"站内网页历史回退"语义（真实 zcode SPA 场景合理）；
   已知边缘：目标站 301 重定向会形成 history 环导致系统 BACK 停留同页，左上按钮不受影响。

## 验证

- Android：模拟器实测（截图 06_auto_open / 07_menu_add / 08_switched_to_new），
  assembleRelease 通过，dist APK 已更新。
- iOS：CI（macos-15）编译绿 + 模拟器截图链路完好（run 35627938876）。
