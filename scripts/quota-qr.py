#!/usr/bin/env python3
"""quota-qr：把电脑端的 LLM 账号凭据导出成二维码，手机 ZCode Remote 扫码导入额度页。

数据来源（按优先级）：
  1. ~/.zcode-switch/accounts/*.json  —— zcode-switch（zsv）的账号库，全部已保存账号；
  2. ~/.zcode/v2/credentials.json     —— ZCode 当前登录账号（没有 zsv 时兜底）。

凭据里的 enc:v1 值用 ZCode 同款算法本地解密（AES-256-GCM，密钥 = SHA256(
"zcode-credential-fallback:{platform}:{home}:{username}")，不联网、不落明文盘）。
企业席位配置从 ~/.zcode-switch/quota-extra.json 读取（按账号名或 id 匹配）。

用法：
  python3 scripts/quota-qr.py            # 生成 HTML 并用浏览器打开，手机扫码导入
  python3 scripts/quota-qr.py --no-open  # 只生成文件

依赖：python3 + cryptography（pip3 install --user cryptography）；
二维码由页面内嵌 JS 绘制（脚本会缓存一份到 ~/.cache/zcode-quota-qr/）。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import urllib.request
from base64 import urlsafe_b64decode
from hashlib import sha256
from pathlib import Path

HOME = Path.home()
ZSV_DIR = HOME / ".zcode-switch"
LIVE_CREDS = HOME / ".zcode" / "v2" / "credentials.json"
CACHE_DIR = HOME / ".cache" / "zcode-quota-qr"
OUT_HTML = CACHE_DIR / "accounts-qr.html"
OUT_JSON = CACHE_DIR / "accounts.json"
QR_LIB_URLS = [
    "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js",
    "https://unpkg.com/qrcode-generator@1.4.4/qrcode.js",
]
# 手机端 QuotaImport.parse 兼容的载荷；单个二维码超过 ~1800 字符会拆成每账号一个码
PAYLOAD_LIMIT = 1800


def enc_secret() -> str:
    env = os.environ.get("ZCODE_CREDENTIAL_SECRET")
    if env:
        return env
    platform = {"darwin": "darwin", "win32": "win32"}.get(sys.platform, "linux")
    username = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    return f"zcode-credential-fallback:{platform}:{HOME}:{username}"


def decrypt(value: str) -> str:
    """enc:v1:{nonce}.{tag}.{ct} → 明文；非 enc 值原样返回。"""
    if not value.startswith("enc:v1:"):
        return value
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    body = value[len("enc:v1:"):]
    nonce_b, tag_b, ct_b = body.split(".")
    key = sha256(enc_secret().encode()).digest()
    nonce = urlsafe_b64decode(nonce_b + "==")
    tag = urlsafe_b64decode(tag_b + "==")
    ct = urlsafe_b64decode(ct_b + "==")
    plain = AESGCM(key).decrypt(nonce, ct + tag, None)
    return plain.decode("utf-8", "replace")


def looks_like_token(v) -> bool:
    return isinstance(v, str) and len(v.strip()) > 20


def account_name_from_creds(creds: dict) -> str:
    active = decrypt(creds.get("oauth:active_provider", "bigmodel"))
    ui = creds.get(f"oauth:{active}:user_info")
    if isinstance(ui, str):
        try:
            info = json.loads(decrypt(ui))
            name = info.get("displayName") or info.get("username") or info.get("email")
            if name:
                return str(name)
        except Exception:
            pass
    return "当前账号"


def extract_from_creds(creds: dict, config: dict | None) -> tuple[list[str], str | None]:
    """从 credentials 快照提取 (coding-plan keys, jwt)。"""
    keys: list[str] = []
    for k, v in creds.items():
        if "coding-plan" in k and k.endswith(":api-key") and isinstance(v, str):
            try:
                plain = decrypt(v)
            except Exception:
                continue
            if looks_like_token(plain) and plain not in keys:
                keys.append(plain)
    if config:
        for pid, p in (config.get("provider") or {}).items():
            if "coding-plan" not in pid:
                continue
            k = (p.get("options") or {}).get("apiKey")
            if looks_like_token(k) and not k.startswith("enc:") and k not in keys:
                keys.append(k)
    jwt = creds.get("zcodejwttoken")
    if isinstance(jwt, str):
        try:
            jwt = decrypt(jwt)
        except Exception:
            jwt = None
    if not looks_like_token(jwt):
        jwt = None
    return keys, jwt


def load_team_config() -> dict:
    """quota-extra.json：{"accounts": {"<账号名或id>": {"key":…, "organization_id":…, "project_id":…}}}"""
    path = ZSV_DIR / "quota-extra.json"
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
        return data.get("accounts") or {}
    except Exception:
        return {}


def build_accounts() -> list[dict]:
    teams = load_team_config()
    out: list[dict] = []

    def emit(name: str, keys: list[str], jwt, ident: str | None):
        if not keys and not jwt:
            return
        team_cfg = teams.get(name) or (teams.get(ident) if ident else None) or {}
        entry = {"n": name, "k": keys[0]}
        if jwt and not keys:
            entry = {"n": name, "jwt": jwt}
        org = team_cfg.get("organization_id")
        proj = team_cfg.get("project_id")
        if org:
            entry["team"] = {"org": org, "proj": proj or ""}
        if entry not in out:
            out.append(entry)

    for path in sorted(glob.glob(str(ZSV_DIR / "accounts" / "*.json"))):
        try:
            data = json.loads(Path(path).read_text())
        except Exception as e:
            print(f"  跳过 {os.path.basename(path)}：{e}", file=sys.stderr)
            continue
        keys, jwt = extract_from_creds(data.get("credentials") or {}, data.get("config"))
        emit(data.get("name") or "未命名账号", keys, jwt, data.get("id"))

    have = {a["n"] for a in out}
    if LIVE_CREDS.exists():
        try:
            creds = json.loads(LIVE_CREDS.read_text())
            keys, jwt = extract_from_creds(creds, None)
            name = account_name_from_creds(creds)
            if name not in have:
                emit(name, keys, jwt, None)
        except Exception as e:
            print(f"  读取当前登录凭据失败：{e}", file=sys.stderr)
    return out


def build_payload(accounts: list[dict]) -> dict:
    return {"v": 1, "type": "zcode-remote-accounts", "accounts": accounts}


def fetch_qr_lib() -> str | None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached = CACHE_DIR / "qrcode.js"
    if cached.exists() and cached.stat().st_size > 10000:
        return cached.read_text()
    for url in QR_LIB_URLS:
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                lib = r.read().decode("utf-8")
            cached.write_text(lib)
            return lib
        except Exception:
            continue
    return None


def html_page(payload: dict, accounts: list[dict]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    chunks = [raw] if len(raw) <= PAYLOAD_LIMIT else [
        json.dumps({"v": 1, "type": "zcode-remote-accounts", "accounts": [a]},
                   ensure_ascii=False, separators=(",", ":"))
        for a in accounts
    ]
    lib = fetch_qr_lib()
    lib_block = f"<script>{lib}</script>" if lib else \
        '<script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"></script>'
    cards = ""
    for i, text in enumerate(chunks):
        cards += f"""
  <div class="card"><div id="qr{i}"></div>
  <p class="label">{('全部账号（' + str(len(accounts)) + ' 个）') if len(chunks) == 1 else '账号：' + accounts[i].get('n', '')}</p></div>"""
    return f"""<!doctype html>
<html lang="zh"><meta charset="utf-8">
<title>ZCode Remote 账号二维码</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #f6f7f9; text-align: center; padding: 40px 16px; }}
  h1 {{ font-size: 20px; }}
  .card {{ display: inline-block; margin: 16px; background: #fff; border-radius: 16px; padding: 24px;
          box-shadow: 0 1px 4px rgba(0,0,0,.08); }}
  .label {{ color: #5c6068; font-size: 13px; margin: 10px 0 0; }}
  details {{ margin-top: 24px; color: #5c6068; font-size: 12px; text-align: left; max-width: 720px;
           margin-inline: auto; white-space: pre-wrap; word-break: break-all; }}
  .warn {{ color: #b45309; font-size: 13px; }}
</style>
<h1>ZCode Remote · 账号额度二维码</h1>
<p class="warn">二维码内含账号凭据，只给信任的设备扫，用完可关闭页面。</p>
<p>打开手机 ZCode Remote → 右上角「账号额度」→「＋」扫码导入</p>
{lib_block}
<script>
const texts = {json.dumps(chunks, ensure_ascii=False)};
texts.forEach((t, i) => {{
  try {{
    const qr = qrcode(0, 'M'); qr.addData(t); qr.make();
    document.getElementById('qr' + i).innerHTML = qr.createSvgTag({{ cellSize: 5, margin: 2 }});
  }} catch (e) {{
    document.getElementById('qr' + i).textContent = '二维码生成失败：' + e + '，请展开下方文本手动复制粘贴';
  }}
}});
</script>
<details><summary>无法扫码？点开复制这段 JSON，到 App 扫码页/手动添加里粘贴</summary>
{raw}
</details>
</html>"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-open", action="store_true", help="只生成文件，不自动打开浏览器")
    args = parser.parse_args()

    try:
        import cryptography  # noqa: F401
    except ImportError:
        print("缺少 cryptography 库：请先运行  pip3 install --user cryptography", file=sys.stderr)
        return 1

    accounts = build_accounts()
    if not accounts:
        print("没有找到任何账号凭据（~/.zcode-switch/accounts/ 与 ~/.zcode/v2/credentials.json 都为空）", file=sys.stderr)
        return 1

    payload = build_payload(accounts)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=1))
    OUT_HTML.write_text(html_page(payload, accounts))
    os.chmod(OUT_JSON, 0o600)

    print(f"共导出 {len(accounts)} 个账号：")
    for a in accounts:
        kind = "席位key" if a.get("team") else ("jwt" if a.get("jwt") else "coding-plan key")
        print(f"  · {a['n']}  ({kind})")
    print(f"\n二维码页面：{OUT_HTML}")
    print(f"JSON（手动粘贴用）：{OUT_JSON}")
    if not args.no_open:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        os.system(f"{opener} '{OUT_HTML}' >/dev/null 2>&1 &")
    return 0


if __name__ == "__main__":
    sys.exit(main())
