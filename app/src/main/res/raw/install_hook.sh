#!/bin/bash
# ZCode 任务结束提醒 hook 安装脚本（在电脑端运行一次）。
# 用法: bash install.sh <ntfy-topic>
#
# 重要：仅写插件文件不够——ZCode 只加载「已注册 marketplace 且在 enabledPlugins
# 里启用」的插件（否则静默跳过，Stop hook 一次都不会跑）。本脚本补齐全部三件：
#   1. marketplace 源目录 + marketplaces 缓存副本 + known_marketplaces.json 注册
#   2. installed_plugins.json 条目（source "./task-notify"，与本地插件同形状）
#   3. ~/.zcode/cli/config.json 的 plugins.enabledPlugins 启用
# 全程幂等，重复运行无害。
#
# 注意：app 内 res/raw/install_hook.sh 是本文件的模板副本（TOPIC 换成 __TOPIC__），
#       改动请两处同步。
set -e

TOPIC="__TOPIC__"
if [ -z "$TOPIC" ] || [ "$TOPIC" = "__TOPIC__" ]; then
  echo "用法: bash install.sh <ntfy-topic>"
  exit 1
fi
case "$TOPIC" in
  *[!A-Za-z0-9_-]*) echo "topic 只允许字母/数字/-/_（1-64 位）"; exit 1 ;;
esac

SRC="$HOME/.zcode/task-notify-marketplace"
CACHE="$HOME/.zcode/cli/plugins/cache/dev-task-notify-local/task-notify"
MP="$HOME/.zcode/cli/plugins/marketplaces/dev-task-notify-local"

printf '# ZCode task-notify 的 ntfy topic\n%s\n' "$TOPIC" > "$HOME/.zcode/task-notify.conf"

# ---- 1. marketplace 源目录（稳定路径；脚本内容内联，不依赖本仓库在场）----
mkdir -p "$SRC/task-notify/.zcode-plugin" "$SRC/task-notify/hooks"

cat > "$SRC/marketplace.json" <<'JSON'
{
  "name": "dev-task-notify-local",
  "plugins": [
    {
      "name": "task-notify",
      "source": "./task-notify",
      "version": "0.1.0",
      "description": "任务结束提醒：Stop 事件推送 ntfy 到手机 ZCode Remote"
    }
  ]
}
JSON

cat > "$SRC/task-notify/.zcode-plugin/plugin.json" <<'JSON'
{
  "name": "task-notify",
  "version": "0.1.0",
  "description": "任务结束提醒：Stop 事件推送 ntfy 到手机 ZCode Remote",
  "author": { "name": "zcode-remote" },
  "hooks": "./hooks/hooks.json"
}
JSON

cat > "$SRC/task-notify/hooks/hooks.json" <<'JSON'
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

cat > "$SRC/task-notify/hooks/task_notify.py" <<'PY'
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

# ---- 2. 缓存副本：installPath 与 marketplaces 缓存 ----
rm -rf "$HOME/.zcode/cli/plugins/cache/dev-task-notify-local" "$MP"
mkdir -p "$(dirname "$CACHE")"
cp -R "$SRC/task-notify" "$CACHE"
cp -R "$SRC" "$MP"

# ---- 3. 三处 JSON 注册（marketplace / 安装表 / 启用开关）----
python3 - "$SRC" "$CACHE" <<'PY'
import datetime, json, os, sys, uuid

src, cache = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
txn = str(uuid.uuid4())
pid = "task-notify@dev-task-notify-local"

p = home + "/.zcode/cli/plugins/known_marketplaces.json"
d = json.load(open(p))
d["marketplaces"] = [m for m in d.get("marketplaces", []) if m.get("id") != "dev-task-notify-local"]
d["marketplaces"].append({
    "id": "dev-task-notify-local",
    "source": {"source": "directory", "path": src},
    "name": "dev-task-notify-local",
    "description": "task-notify：ZCode 任务结束推送到手机 ZCode Remote",
    "addedAt": now, "lastUpdated": now, "pluginCount": 1, "cacheTransactionId": txn,
})
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)

p = home + "/.zcode/cli/plugins/installed_plugins.json"
d = json.load(open(p))
d["plugins"] = [x for x in d.get("plugins", []) if x.get("id") != pid]
d["plugins"].append({
    "id": pid, "name": "task-notify", "marketplace": "dev-task-notify-local",
    "version": "0.1.0", "installPath": cache,
    "installedAt": now, "updatedAt": now, "scope": "user",
    "source": "./task-notify", "cacheTransactionId": txn,
})
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)

p = home + "/.zcode/cli/config.json"
d = json.load(open(p))
d.setdefault("plugins", {}).setdefault("enabledPlugins", {})[pid] = True
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)
print("插件已注册并启用:", pid)
PY

echo "安装完成。重启 ZCode 桌面端后生效（必须重启，插件在启动时加载）。"
echo "立即验证推送: python3 \"$SRC/task-notify/hooks/task_notify.py\" --test"
