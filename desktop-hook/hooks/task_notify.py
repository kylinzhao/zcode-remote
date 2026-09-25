#!/usr/bin/env python3
"""task-notify: ZCode Stop hook → ntfy 推送。

Stop 事件（一轮任务结束）触发，把通知 POST 到 ntfy.sh 的私有 topic，
手机端 ZCode Remote 内嵌订阅接收并点亮红点。所有异常静默，绝不打断会话。

推送文案：标题 = 主机名 · 项目名；正文 = 任务内容摘要（Stop 事件的
last_assistant_message，兜底读本会话 rollout 流的最后一条模型回复），
取第一条非空行、去 markdown 记号、截 100 字。

配置：~/.zcode/task-notify.conf 第一行 = topic（安装脚本写入）；
      环境变量 ZCODE_TASK_NOTIFY_TOPIC 优先。
限流：默认 60s 内只推一条（过滤交互式连续短回复），ZCODE_TASK_NOTIFY_MIN_GAP 覆盖（0=关闭）。
测试：python3 task_notify.py --test
"""
import json
import os
import re
import socket
import sys
import time
import urllib.request

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
    """rollout 兜底：~/.zcode/cli/rollout/model-io-sess_<id>.jsonl 的最后一条模型文本回复。

    每行是一次完整模型请求（含 request 的大体积行）；只从文件尾倒序找 response.text。
    任何异常返回空，由调用方退回默认文案。
    """
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
