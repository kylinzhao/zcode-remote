# 电脑端 ZCode 设置指南

把 ZCode Remote 发给别人用时，对方的电脑需要做什么。手机侧只装 APK 即可，本文只讲电脑端。

## 前提

- 电脑端 **ZCode 桌面版 v3.14+**（「远程访问」内置于该版本）
- 能正常登录 ZCode

## 基础功能：什么都不用调

扫码绑定、远程操控、**任务结束小红点（页面检测通道）** 都是开箱即用的——对方只需：

1. 打开电脑端 ZCode → 「远程访问」；
2. 用 ZCode Remote 扫屏幕上的二维码。

App 自动识别、保存、连接。电脑端不装任何东西。

## 可选：锁屏也能收到的任务结束推送（ntfy 通道）

页面检测依赖 App 进程存活：锁屏久了、进程被系统杀了，红点/通知就不会来。想要**任何时刻**
都能收到，电脑端装一个 `task-notify` 插件（ZCode 的 Stop hook，任务结束时推送到手机）。

推送文案 = **「电脑名 · 项目名」+ 任务内容摘要**（取自任务收尾回复的首行，截 100 字），
一眼知道是哪台电脑、做完的是什么事。

### 安装（每台电脑一次，约一分钟）

最省事的方式：把 README「通道二」里的 **Agent 安装提示词**整段复制，发给那台电脑上的 ZCode
（把 `<topic>` 换成手机上生成的主题，忘了换 agent 也会向你要），其余由 agent 代劳。

手动方式：

1. **手机**：ZCode Remote → 长按该实例（或编辑）→ 「生成」得到私有 topic →
   点「复制电脑端安装命令」；
2. **电脑**：把命令粘贴进终端，回车。脚本做的事：
   - 写入插件到 `~/.zcode/cli/plugins/cache/dev-task-notify-local/task-notify/0.1.0/`
     （含 Stop hook，源码见本仓库 `desktop-hook/`）；
   - 把 topic 写进 `~/.zcode/task-notify.conf`；
   - 在 `~/.zcode/cli/plugins/installed_plugins.json` 注册插件（幂等，重复运行无害）；
3. **重启电脑端 ZCode 桌面端**——插件在启动时加载，不重启不生效；
4. **验证**：终端运行
   ```bash
   python3 ~/.zcode/cli/plugins/cache/dev-task-notify-local/task-notify/0.1.0/hooks/task_notify.py --test
   ```
   手机应立刻收到「电脑名 · 测试推送」标题的推送。

不用手机复制命令也行：克隆本仓库后 `bash desktop-hook/install.sh <你的topic>`。

### 它改了什么 / 怎么卸载

不改 ZCode 本体，只加了一个用户级插件 + 一个 topic 配置文件。卸载：

```bash
rm -rf ~/.zcode/cli/plugins/cache/dev-task-notify-local \
       ~/.zcode/task-notify.conf ~/.zcode/task-notify.state
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/.zcode/cli/plugins/installed_plugins.json")
d = json.load(open(p))
d["plugins"] = [x for x in d["plugins"] if x.get("id") != "task-notify@dev-task-notify-local"]
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)
EOF
```

然后重启 ZCode 桌面端。

### 常见问题

- **装完没反应？** 九成是没重启 ZCode 桌面端。
- **收到的频率？** hook 默认 60 秒限流（交互式连续短回复只推一条，避免轰炸）；
  环境变量 `ZCODE_TASK_NOTIFY_MIN_GAP=0` 可关闭限流。
- **隐私？** 推送经公共服务 ntfy.sh 中转（免费、无需注册）。内容为
  主机名 / 项目目录名 / 任务收尾回复的**首行摘要**（约 100 字，去掉了 markdown 记号）——
  因此可能含对话内容，介意的话把 hook 里的 `summarize()` 调用去掉即退回「任务执行完毕」。
  topic 名即收信凭证（不知道 topic 就收不到），请像密码一样保管，勿外传。
- **公司网络封了 ntfy.sh？** 该通道不可用，但基础功能（走 `zcode.z.ai` 中继）不受影响；
  页面检测通道照常工作。
- **iOS？** 推送通道未实现（APNs 需付费开发者账号），iPhone 上只有页面检测通道。
