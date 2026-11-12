#!/usr/bin/env node
// relay 通道读写脚本：write / read
// accesskey 自动读 keys/<name>.key；--hmac 时自动加 X-Ts / X-Sig。输出不含钥原文。
import { readFileSync, existsSync } from "node:fs";
import { createHmac } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BASE = (process.env.RELAY_URL || "").replace(/\/$/, "");
if (!BASE) { console.error("先设 RELAY_URL 环境变量为你的通道服务器地址（自部署的地址，或 pet-channel.json 里的 server）"); process.exit(1); }
const KEYS = join(HERE, "keys");

function channelKey(name) {
  const f = join(KEYS, `${name}.key`);
  if (!existsSync(f)) { console.error(`找不到 keys/${name}.key，先用 relay-admin.mjs create ${name}`); process.exit(1); }
  return readFileSync(f, "utf8").trim();
}

const [cmd, name, ...rest] = process.argv.slice(2);
const has = (flag) => rest.includes(flag);
const opt = (flag) => {
  const hit = rest.find((a) => a.startsWith(flag + "="));
  return hit ? hit.slice(flag.length + 1) : null;
};

if (cmd === "write") {
  const body = rest.find((a) => !a.startsWith("--") && !a.includes("=")) ?? opt("--body") ?? "";
  const key = channelKey(name);
  const headers = { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
  if (has("--hmac")) {
    const ts = String(Math.floor(Date.now() / 1000));
    const sig = createHmac("sha256", key).update(ts + "." + body).digest("hex");
    headers["X-Ts"] = ts;
    headers["X-Sig"] = sig;
  }
  const ifSeq = opt("--if-seq");
  if (ifSeq !== null) headers["If-Seq"] = ifSeq;
  const res = await fetch(`${BASE}/c/${name}`, { method: "POST", headers, body });
  const text = await res.text();
  console.log(`write ${name}: HTTP ${res.status} ${text}`);
  if (res.status !== 200) process.exit(1);
} else if (cmd === "read") {
  const key = channelKey(name);
  const since = opt("--since");
  const url = `${BASE}/c/${name}` + (since !== null ? `?since=${since}` : "");
  const res = await fetch(url, { headers: { Authorization: `Bearer ${key}` } });
  if (res.status === 204) { console.log(`read ${name}: HTTP 204 (no change)`); process.exit(0); }
  const text = await res.text();
  console.log(`read ${name}: HTTP ${res.status} ${text}`);
  if (res.status !== 200) process.exit(1);
} else {
  console.error("用法: relay.mjs write <name> '<body>' [--hmac] [--if-seq=N] | read <name> [--since=N]");
  process.exit(1);
}
