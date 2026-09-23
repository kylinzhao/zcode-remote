#!/bin/bash
# ZCode 任务结束提醒 hook 安装脚本（在电脑端运行一次）。
# 用法: bash install.sh <ntfy-topic>
# 作用：安装 task-notify 插件（Stop hook → ntfy.sh 推送）并写入 topic 配置。
# 注意：app 内 res/raw/install_hook.sh 是本文件的模板副本（TOPIC="${1:-}" 换成
#       TOPIC="__TOPIC__"），改动请两处同步。
set -e

TOPIC="${1:-}"
if [ -z "$TOPIC" ]; then
  echo "用法: bash install.sh <ntfy-topic>"
  exit 1
fi
case "$TOPIC" in
  *[!A-Za-z0-9_-]*) echo "topic 只允许字母/数字/-/_（1-64 位）"; exit 1 ;;
esac

BASE="$HOME/.zcode/cli/plugins/cache/dev-task-notify-local/task-notify/0.1.0"
mkdir -p "$BASE/hooks" "$BASE/.zcode-plugin"

printf '# ZCode task-notify 的 ntfy topic\n%s\n' "$TOPIC" > "$HOME/.zcode/task-notify.conf"

cat > "$BASE/.zcode-plugin/plugin.json" <<'JSON'
{
  "name": "task-notify",
  "version": "0.1.0",
  "description": "任务结束提醒：Stop 事件推送 ntfy 到手机 ZCode Remote",
  "author": { "name": "zcode-remote" },
  "hooks": "./hooks/hooks.json"
}
JSON

cat > "$BASE/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/task_notify.py\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
JSON

cat > "$BASE/hooks/task_notify.py" <<'PY'
#!/usr/bin/env python3
"""task-notify: ZCode Stop hook → ntfy 推送。所有异常静默，绝不打断会话。"""
import json, os, socket, sys, time, urllib.request

CONF = os.path.expanduser("~/.zcode/task-notify.conf")
STATE = os.path.expanduser("~/.zcode/task-notify.state")


def read_topic():
    env = os.environ.get("ZCODE_TASK_NOTIFY_TOPIC", "").strip()
    if env:
        return env
    try:
        with open(CONF, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


def min_gap():
    raw = os.environ.get("ZCODE_TASK_NOTIFY_MIN_GAP", "60").strip()
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 60.0


def under_rate_limit(min_gap):
    if min_gap <= 0:
        return False
    try:
        last = float(open(STATE, encoding="utf-8").read().strip())
        if time.time() - last < min_gap:
            return True
    except (OSError, ValueError):
        pass
    return False


def main():
    if "--test" in sys.argv:
        project = "（测试推送）"
    else:
        try:
            data = json.load(sys.stdin)
        except Exception:
            data = {}
        cwd = (data.get("cwd") or "").rstrip("/")
        project = f"（{os.path.basename(cwd)}）" if cwd else ""
    topic = read_topic()
    if not topic or under_rate_limit(min_gap()):
        return
    host = socket.gethostname()
    if host.endswith(".local"):
        host = host[:-len(".local")]
    body = json.dumps({
        "topic": topic,
        "title": "ZCode 任务已结束",
        "message": f"{host} 的任务执行完毕{project}",
        "tags": ["white_check_mark"],
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://ntfy.sh/", data=body, headers={"Content-Type": "application/json"}
    )
    try:
        urllib.request.urlopen(req, timeout=5).close()
        with open(STATE, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
PY

python3 - "$BASE" <<'PY'
import datetime, json, os, sys, uuid

base = sys.argv[1]
path = os.path.expanduser("~/.zcode/cli/plugins/installed_plugins.json")
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {"version": 1, "plugins": []}
entry = {
    "id": "task-notify@dev-task-notify-local",
    "name": "task-notify",
    "marketplace": "dev-task-notify-local",
    "version": "0.1.0",
    "installPath": base,
    "installedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "scope": "user",
    "source": "task-notify-local",
    "cacheTransactionId": str(uuid.uuid4()),
}
plugins = [p for p in data.get("plugins", []) if p.get("id") != entry["id"]]
plugins.append(entry)
data["plugins"] = plugins
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
print("插件已注册:", entry["id"])
PY

echo "安装完成。重启 ZCode 桌面端后生效。"
echo "立即验证推送: python3 \"$BASE/hooks/task_notify.py\" --test"
