#!/usr/bin/env python3
"""task-notify: ZCode Stop hook → ntfy 推送。

Stop 事件（一轮任务结束）触发，把通知 POST 到 ntfy.sh 的私有 topic，
手机端 ZCode Remote 内嵌订阅接收并点亮红点。所有异常静默，绝不打断会话。

推送文案：标题 = 主机名 · 项目名；正文 = 任务内容摘要（Stop 事件的
last_assistant_message，兜底读本会话 rollout 流的最后一条模型回复），
取第一条非空行、去 markdown 记号、截 100 字。
失败识别：对摘要同样的开头 1-2 行做行首锚定的失败特征匹配（任务/构建/…失败、
无法完成、Error:/FAILED 等），命中则 ❌ 标签 + 正文加 ❌ 前缀，兜底文案改
「任务执行失败」；识别是启发式的，宁漏勿误报。

配置：~/.zcode/task-notify.conf 第一行 = topic（安装脚本写入）；
      环境变量 ZCODE_TASK_NOTIFY_TOPIC 优先。
限流：默认 60s 内只推一条（过滤交互式连续短回复），ZCODE_TASK_NOTIFY_MIN_GAP 覆盖（0=关闭）。
测试：python3 task_notify.py --test        成功样式
      python3 task_notify.py --test-fail   失败样式
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

# 失败特征：行首锚定，避免「修复了测试失败的问题」这类成功回顾误报；
# 失败词后紧跟「的问题/情况/原因」等回顾性宾语也不算。主语与失败词之间
# 的填充不含句读标点，「任务完成。附：上次失败…」这类跨句拼接不会命中。
FAIL_LINE_RES = [
    re.compile(
        r"^(?:任务|执行|构建|编译|测试|运行|部署|发布|命令|操作|验证|检查|安装|卸载"
        r"|推送|请求|调用|上传|下载)"
        r"[^。！？；，,\n]{0,8}?"
        r"(?:失败|出错|报错|未完成|无法完成|未能完成|未通过|不通过|中止|中断|异常终止|超时)"
        r"(?!\s*的?(?:问题|情况|原因|风险|告警|提示))"
    ),
    re.compile(r"^(?:失败|出错|报错|超时)(?!\s*的?(?:问题|情况|原因|风险|告警|提示))"),
    re.compile(r"^(?:无法|未能)(?:完成|实现|继续|执行|定位|找到|创建|打开|读取|写入)"),
    re.compile(r"^(?:出了|出现)(?:点)?(?:问题|错误|异常)|^遇到(?:了)?(?:错误|异常|问题)"),
    re.compile(r"^(?:error|failed|fatal|exception|traceback)\b", re.IGNORECASE),
]


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


def clean_lines(text):
    """逐行去 markdown 记号，返回非空行；摘要与失败识别共用。"""
    lines = []
    for ln in text.splitlines():
        ln = ln.strip().lstrip("#").strip()
        ln = ln.replace("**", "").replace("__", "").replace("`", "")
        ln = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", ln)
        ln = re.sub(r"\s+", " ", ln).strip()
        ln = ln.lstrip("-* ").strip()
        if not ln or ln.startswith(("•",)):
            continue
        lines.append(ln)
    return lines


def looks_failed(lines):
    """失败识别：只看消息开头 1-2 行——推送摘要同样取自这里，❌ 与推送正文永不矛盾。"""
    return any(rx.search(ln) for ln in lines[:2] for rx in FAIL_LINE_RES)


def summarize(lines):
    """任务内容摘要：首段太短（纯「## 完成」式标题）才拼下一段。"""
    parts = []
    for ln in lines:
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
    failed = False
    if "--test" in sys.argv or "--test-fail" in sys.argv:
        project = "测试推送"
        summary = "推送文案验证：标题=电脑·项目，正文=任务内容摘要。"
        failed = "--test-fail" in sys.argv
    else:
        try:
            data = json.load(sys.stdin)
        except Exception:
            data = {}
        cwd = (data.get("cwd") or "").rstrip("/")
        project = os.path.basename(cwd) if cwd else ""
        text = str(data.get("last_assistant_message") or "").strip()
        if not text:
            text = last_rollout_text(str(data.get("session_id") or ""))
        lines = clean_lines(text)
        failed = looks_failed(lines)
        summary = summarize(lines)
    topic = read_topic()
    if not topic or under_rate_limit(min_gap()):
        return
    host = socket.gethostname()
    if host.endswith(".local"):
        host = host[:-len(".local")]
    title = f"{host} · {project}" if project else host
    suffix = ('（' + project + '）') if project else ''
    if failed:
        message = f"❌ {summary}" if summary else f"任务执行失败{suffix}"
        tags = ["x"]
    else:
        message = summary or f"任务执行完毕{suffix}"
        tags = ["white_check_mark"]
    body = json.dumps({
        "topic": topic,
        "title": title,
        "message": message,
        "tags": tags,
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
