#!/usr/bin/env python3
"""部署通用通道 Worker（脚本名 relay）到运行者自己的 Cloudflare 账号。
账号 ID：优先环境变量 CF_ACCOUNT_ID，未设时经 API 自动取账号列表第一个。
走 custom.cloudflare 凭证 surrogate；Durable Objects（RegistryDO/ChannelDO，SQLite 类）。
主钥：本机生成 32 字节随机，落 keys/admin.key（600），经 CF API 设为 Worker secret ADMIN_KEY。
脚本只打印钥的长度与状态，绝不打印钥本身。重复跑是更新（幂等）。"""
import json, os, secrets, sys, urllib.request, urllib.error
sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

ACC = os.environ.get("CF_ACCOUNT_ID", "")  # 未设时在 main() 里自动发现
NAME = "relay"
CRED = "custom.cloudflare"
HOSTS = ("api.cloudflare.com",)
BASE = "https://api.cloudflare.com/client/v4"
HERE = os.path.dirname(os.path.abspath(__file__))
KEYS_DIR = os.path.join(HERE, "keys")
ADMIN_KEY_FILE = os.path.join(KEYS_DIR, "admin.key")
DO_CLASSES = ["RegistryDO", "ChannelDO"]

def api(method, path, data=None, ctype="application/json"):
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": ctype} if data else {})
    add_surrogate_to_request(req, CRED, allowed_hosts=HOSTS)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, read_json_response(resp)
    except urllib.error.HTTPError as e:
        try: detail = e.read().decode()[:1200]
        except Exception: detail = ""
        return e.code, {"http_error": e.code, "detail": detail}

def ensure_admin_key():
    os.makedirs(KEYS_DIR, mode=0o700, exist_ok=True)
    try: os.chmod(KEYS_DIR, 0o700)
    except Exception: pass
    if os.path.exists(ADMIN_KEY_FILE):
        key = open(ADMIN_KEY_FILE).read().strip()
        print(f"admin key: exists (len={len(key)})")
        return key
    key = secrets.token_urlsafe(32)  # 32 字节随机 → base64url 43 字符
    fd = os.open(ADMIN_KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(key + "\n")
    os.chmod(ADMIN_KEY_FILE, 0o600)
    print(f"admin key: generated (len={len(key)}), saved to keys/admin.key (600)")
    return key

def script_has_do():
    st, res = api("GET", f"/accounts/{ACC}/workers/scripts/{NAME}/settings")
    if st != 200:
        return False
    bindings = (res.get("result") or {}).get("bindings") or []
    return any(b.get("type") == "durable_object_namespace" for b in bindings)

def upload(include_migrations):
    metadata = {
        "main_module": "worker.js",
        "compatibility_date": "2025-04-01",
        "bindings": [
            {"name": "REGISTRY", "type": "durable_object_namespace", "class_name": "RegistryDO"},
            {"name": "CHANNEL", "type": "durable_object_namespace", "class_name": "ChannelDO"},
        ],
    }
    if include_migrations:
        metadata["migrations"] = {"new_sqlite_classes": DO_CLASSES}
    boundary = "----cfworkerboundaryRELAY01"
    code = open(os.path.join(HERE, "worker.js"), "rb").read()
    parts = []
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".encode() + json.dumps(metadata).encode() + b"\r\n")
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\nContent-Type: application/javascript+module\r\n\r\n".encode() + code + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    print(f"uploading worker.js, {len(code)/1e3:.1f} KB raw, migrations={include_migrations}")
    return api("PUT", f"/accounts/{ACC}/workers/scripts/{NAME}", data=body,
               ctype=f"multipart/form-data; boundary={boundary}")

def discover_account():
    st, res = api("GET", "/accounts")
    accounts = res.get("result") or []
    if st != 200 or not accounts:
        print("无法列出 Cloudflare 账号（检查 token 权限），也可设置环境变量 CF_ACCOUNT_ID 后重试")
        sys.exit(1)
    return accounts[0]["id"]


def main():
    global ACC
    if not ACC:
        ACC = discover_account()
        print(f"account: auto-discovered id={ACC}")
    admin_key = ensure_admin_key()
    need_mig = not script_has_do()
    st, res = upload(need_mig)
    if st != 200 and need_mig and "migration" in json.dumps(res).lower():
        print("migration rejected, retrying without migrations")
        st, res = upload(False)
    print("deploy:", st, json.dumps(res)[:600])
    if st != 200:
        sys.exit(1)
    # 设置主钥 secret
    st, res = api("PUT", f"/accounts/{ACC}/workers/scripts/{NAME}/secrets",
                  data=json.dumps({"name": "ADMIN_KEY", "text": admin_key, "type": "secret_text"}).encode())
    print("secret ADMIN_KEY set:", st, "(value not printed)")
    if st not in (200, 201):
        print(json.dumps(res)[:400])
        sys.exit(1)
    st, res = api("POST", f"/accounts/{ACC}/workers/scripts/{NAME}/subdomain",
                  data=json.dumps({"enabled": True}).encode())
    print("subdomain:", st, json.dumps(res)[:300])
    st, res = api("GET", f"/accounts/{ACC}/workers/subdomain")
    sub = (res.get("result") or {}).get("subdomain")
    if sub:
        print(f"URL: https://relay.{sub}.workers.dev/ （管理/读写脚本记得设 RELAY_URL 为此地址）")
    else:
        print("URL: https://relay.<你的 workers.dev 子域>.workers.dev/（子域查询失败，手动拼）")

if __name__ == "__main__":
    main()
