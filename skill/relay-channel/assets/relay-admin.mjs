#!/usr/bin/env node
// relay 管理脚本：create / list / rotate / delete
// 主钥自动读 keys/admin.key；新建/轮换拿到的 accesskey 直接落 keys/<name>.key（600）。
// 输出只报通道名/模式/钥长度，绝不打印钥原文。
import { readFileSync, writeFileSync, existsSync, rmSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BASE = (process.env.RELAY_URL || "https://relay.nonzero-e3c.workers.dev").replace(/\/$/, "");
const KEYS = join(HERE, "keys");

function adminKey() {
  const f = join(KEYS, "admin.key");
  if (!existsSync(f)) { console.error("找不到 keys/admin.key，先跑 deploy.py"); process.exit(1); }
  return readFileSync(f, "utf8").trim();
}
async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${adminKey()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = JSON.parse(text); } catch { /* keep null */ }
  return { status: res.status, data };
}
function saveChannelKey(name, key) {
  const f = join(KEYS, `${name}.key`);
  writeFileSync(f, key + "\n", { mode: 0o600 });
  chmodSync(f, 0o600);
  return f;
}

const [cmd, name, ...rest] = process.argv.slice(2);
const opt = (flag) => {
  const hit = rest.find((a) => a.startsWith(flag + "="));
  return hit ? hit.slice(flag.length + 1) : null;
};

if (cmd === "create") {
  const mode = opt("--mode") || "state";
  const hmac = !rest.includes("--no-hmac");
  const { status, data } = await api("POST", "/admin/channels", { name, mode, hmac });
  if (status !== 201) { console.error("create failed:", status, JSON.stringify(data)); process.exit(1); }
  saveChannelKey(name, data.accesskey);
  console.log(`created: name=${data.name} mode=${data.mode} hmac=${data.hmac} accesskey len=${data.accesskey.length} -> keys/${name}.key (600)`);
} else if (cmd === "list") {
  const { status, data } = await api("GET", "/admin/channels");
  if (status !== 200) { console.error("list failed:", status, JSON.stringify(data)); process.exit(1); }
  for (const ch of data) {
    console.log(`${ch.name}\tmode=${ch.mode}\thmac=${ch.hmac}\tlast_seq=${ch.last_seq}\tlast_write_at=${ch.last_write_at ?? "-"}\tcreated_at=${ch.created_at}`);
  }
  if (!data.length) console.log("(no channels)");
} else if (cmd === "rotate") {
  const { status, data } = await api("POST", `/admin/channels/${name}/rotate`);
  if (status !== 200) { console.error("rotate failed:", status, JSON.stringify(data)); process.exit(1); }
  saveChannelKey(name, data.accesskey);
  console.log(`rotated: name=${name} new accesskey len=${data.accesskey.length} -> keys/${name}.key updated (600), old key invalidated`);
} else if (cmd === "delete") {
  const { status, data } = await api("DELETE", `/admin/channels/${name}`);
  if (status !== 200) { console.error("delete failed:", status, JSON.stringify(data)); process.exit(1); }
  const f = join(KEYS, `${name}.key`);
  if (existsSync(f)) rmSync(f);
  console.log(`deleted: name=${name} (local key file removed if present)`);
} else {
  console.error("用法: relay-admin.mjs create <name> [--mode=state|log] [--no-hmac] | list | rotate <name> | delete <name>");
  process.exit(1);
}
