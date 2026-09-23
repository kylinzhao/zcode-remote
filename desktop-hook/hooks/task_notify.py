#!/usr/bin/env python3
"""task-notify: ZCode Stop hook → ntfy 推送。

Stop 事件（一轮任务结束）触发，把通知 POST 到 ntfy.sh 的私有 topic，
手机端 ZCode Remote 内嵌订阅接收并点亮红点。所有异常静默，绝不打断会话。

配置：~/.zcode/task-notify.conf 第一行 = topic（安装脚本写入）；
      环境变量 ZCODE_TASK_NOTIFY_TOPIC 优先。
限流：默认 60s 内只推一条（过滤交互式连续短回复），ZCODE_TASK_NOTIFY_MIN_GAP 覆盖（0=关闭）。
测试：python3 task_notify.py --test
"""
import json
import os
import socket
import sys
import time
import urllib.request

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


def mark_pushed():
    try:
        with open(STATE, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
    except OSError:
        pass


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
        mark_pushed()
    except Exception:
        pass


def min_gap():
    raw = os.environ.get("ZCODE_TASK_NOTIFY_MIN_GAP", "60").strip()
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 60.0


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
