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
"""task-notify: ZCode Stop hook → ntfy 推送。所有异常静默，绝不打断会话。

标题=主机名·项目名；正文=任务内容摘要（last_assistant_message，兜底读 rollout）。
与 desktop-hook/hooks/task_notify.py 保持同步（此处为内联安装副本）。"""
import json, os, re, socket, sys, time, urllib.request

CONF = os.path.expanduser("~/.zcode/task-notify.conf")
STATE = os.path.expanduser("~/.zcode/task-notify.state")
SUMMARY_MAX = 100  # 推送正文截断长度


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


def summarize(data):
    """任务内容摘要：Stop 事件自带的 last_assistant_message 优先，兜底读本会话 rollout。"""
    text = str(data.get("last_assistant_message") or "").strip()
    if not text:
        text = last_rollout_text(str(data.get("session_id") or ""))
    if not text:
        return None
    # 逐行去 markdown 记号；首段太短（纯「## 完成」式标题）才拼下一段
    parts = []
    for ln in text.splitlines():
        ln = ln.strip().lstrip("#").strip()
        ln = ln.replace("**", "").replace("__", "").replace("`", "")
        ln = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", ln)
        ln = re.sub(r"\s+", " ", ln).strip()
        ln = ln.lstrip("-* ").strip()
        if not ln or ln.startswith(("•",)):
            continue
        parts.append(ln)
        if len(parts[0]) >= 15 or len(parts) >= 2:
            break
    summary = ":".join(parts)
    if len(summary) > SUMMARY_MAX:
        summary = summary[:SUMMARY_MAX].rstrip() + "…"
    return summary or None


def last_rollout_text(session_id):
    """rollout 兜底：~/.zcode/cli/rollout/model-io-sess_<id>.jsonl 的最后一条模型文本回复。"""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
        return ""
    path = os.path.expanduser(f"~/.zcode/cli/rollout/model-io-sess_{session_id}.jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 512 * 1024))
            tail = f.read()
        for raw in reversed(tail.splitlines()):
            line = raw.strip()
            if not line or not line.startswith(b"{"):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue  # 截断的大行，跳过
            text = str((rec.get("response") or {}).get("text") or "").strip()
            if text:
                return text
    except (OSError, ValueError):
        pass
    return ""


def main():
    if "--test" in sys.argv:
        project = "测试推送"
        summary = "推送文案升级验证：标题=电脑·项目，正文=任务内容摘要。"
    else:
        try:
            data = json.load(sys.stdin)
        except Exception:
            data = {}
        cwd = (data.get("cwd") or "").rstrip("/")
        project = os.path.basename(cwd) if cwd else ""
        summary = summarize(data)
    topic = read_topic()
    if not topic or under_rate_limit(min_gap()):
        return
    host = socket.gethostname()
    if host.endswith(".local"):
        host = host[:-len(".local")]
    title = f"{host} · {project}" if project else host
    message = summary or f"任务执行完毕{('（' + project + '）') if project else ''}"
    body = json.dumps({
        "topic": topic,
        "title": title,
        "message": message,
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
