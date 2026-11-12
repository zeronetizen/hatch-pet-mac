// relay — 通用数据通道服务（Cloudflare Worker + Durable Objects）
// 通道：state（只留最新一条）/ log（追加保留最近 100 条）双模式。
// 读写同一把 accesskey（只存 SHA-256 哈希）；可选 HMAC 签名校验；限频与条件写。
// 日志只记通道名/动作/seq/结果码，不记 body 与任何钥。

const NAME_RE = /^[a-z0-9][a-z0-9-_]{1,63}$/;
const MAX_BODY = 65536; // 64KB
const RATE_WRITE = 60; // 每通道每分钟
const RATE_READ = 600;
const RATE_WINDOW_MS = 60000;
const LOG_KEEP = 100;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
function err(status, code, message, extra = {}) {
  return json({ error: code, message, ...extra }, status);
}
function logLine(...parts) {
  console.log("[relay]", ...parts);
}

const enc = new TextEncoder();
async function sha256hex(text) {
  const buf = await crypto.subtle.digest("SHA-256", enc.encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function hmacHex(keyText, msgText) {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(keyText), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msgText));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
function newAccessKey() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function bearer(req) {
  const h = req.headers.get("Authorization") || "";
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}
function parseData(body) {
  if (body === null || body === undefined) return null;
  try { return JSON.parse(body); } catch { return body; }
}

// ---------------- RegistryDO：通道元数据与管理 ----------------
export class RegistryDO {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }
  async meta(name) {
    return (await this.ctx.storage.get("ch:" + name)) || null;
  }
  async fetch(req) {
    const url = new URL(req.url);
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    try {
      if (url.pathname === "/create") {
        const { name, mode, hmac, keyHash } = body;
        if (await this.meta(name)) return err(409, "channel_exists", "通道已存在");
        const meta = { name, mode, hmac: !!hmac, keyHash, created_at: Date.now() };
        await this.ctx.storage.put("ch:" + name, meta);
        logLine("admin create", name, mode, "hmac=" + meta.hmac, "201");
        return json({ ok: true }, 201);
      }
      if (url.pathname === "/get") {
        const meta = await this.meta(body.name);
        return json({ meta });
      }
      if (url.pathname === "/list") {
        const all = await this.ctx.storage.list({ prefix: "ch:" });
        return json({ channels: [...all.values()] });
      }
      if (url.pathname === "/rotate") {
        const meta = await this.meta(body.name);
        if (!meta) return err(404, "not_found", "通道不存在");
        meta.keyHash = body.keyHash;
        await this.ctx.storage.put("ch:" + body.name, meta);
        logLine("admin rotate", body.name, "200");
        return json({ ok: true });
      }
      if (url.pathname === "/delete") {
        const meta = await this.meta(body.name);
        if (!meta) return err(404, "not_found", "通道不存在");
        await this.ctx.storage.delete("ch:" + body.name);
        logLine("admin delete", body.name, "200");
        return json({ ok: true });
      }
      return err(404, "not_found", "未知注册表操作");
    } catch (e) {
      logLine("registry error", String(e && e.message || e));
      return err(500, "internal", "注册表内部错误");
    }
  }
}

// ---------------- ChannelDO：单通道数据 + 限频 ----------------
export class ChannelDO {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.writeHits = [];
    this.readHits = [];
  }
  rateCheck(kind) {
    const now = Date.now();
    const arr = kind === "write" ? this.writeHits : this.readHits;
    while (arr.length && now - arr[0] > RATE_WINDOW_MS) arr.shift();
    const limit = kind === "write" ? RATE_WRITE : RATE_READ;
    if (arr.length >= limit) return false;
    arr.push(now);
    return true;
  }
  async currentSeq(mode) {
    if (mode === "state") {
      const cur = await this.ctx.storage.get("state");
      return cur ? cur.seq : 0;
    }
    return (await this.ctx.storage.get("seq")) || 0;
  }
  async fetch(req) {
    const url = new URL(req.url);
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    try {
      if (url.pathname === "/write") {
        const { name, mode, rawBody, contentType, ifSeq } = body;
        if (!this.rateCheck("write")) {
          logLine("write", name, "rate-limited", "429");
          return err(429, "rate_limited", "写限频：每通道 60 次/分钟");
        }
        const curSeq = await this.currentSeq(mode);
        if (ifSeq !== null && ifSeq !== undefined && Number(ifSeq) !== curSeq) {
          logLine("write", name, "if-seq mismatch cur=" + curSeq, "409");
          return err(409, "seq_conflict", "If-Seq 与当前 seq 不符", { seq: curSeq });
        }
        const seq = curSeq + 1;
        const ts = Date.now();
        if (mode === "state") {
          await this.ctx.storage.put("state", { seq, ts, content_type: contentType, body: rawBody });
        } else {
          const items = (await this.ctx.storage.get("items")) || [];
          items.push({ seq, ts, content_type: contentType, body: rawBody });
          while (items.length > LOG_KEEP) items.shift();
          await this.ctx.storage.put("items", items);
          await this.ctx.storage.put("seq", seq);
        }
        await this.ctx.storage.put("last_write_at", ts);
        logLine("write", name, "seq=" + seq, "200");
        return json({ seq, ts });
      }
      if (url.pathname === "/read") {
        const { name, mode, since } = body;
        if (!this.rateCheck("read")) {
          logLine("read", name, "rate-limited", "429");
          return err(429, "rate_limited", "读限频：每通道 600 次/分钟");
        }
        if (mode === "state") {
          const cur = await this.ctx.storage.get("state");
          const curSeq = cur ? cur.seq : 0;
          if (since !== null && since !== undefined && Number(since) >= curSeq) {
            logLine("read", name, "since=" + since, "no-change", "204");
            return new Response(null, { status: 204 });
          }
          logLine("read", name, "seq=" + curSeq, "200");
          if (!cur) return json({ seq: 0, ts: null, content_type: null, data: null });
          return json({ seq: cur.seq, ts: cur.ts, content_type: cur.content_type, data: parseData(cur.body) });
        }
        // log 模式
        const items = (await this.ctx.storage.get("items")) || [];
        const curSeq = items.length ? items[items.length - 1].seq : ((await this.ctx.storage.get("seq")) || 0);
        let out;
        if (since === null || since === undefined) out = items.slice(-20);
        else out = items.filter((it) => it.seq > Number(since)).slice(0, 100);
        logLine("read", name, "log items=" + out.length, "200");
        return json({
          seq: curSeq,
          items: out.map((it) => ({ seq: it.seq, ts: it.ts, data: parseData(it.body) })),
        });
      }
      if (url.pathname === "/meta") {
        const mode = body.mode;
        const last_seq = await this.currentSeq(mode);
        const last_write_at = (await this.ctx.storage.get("last_write_at")) || null;
        const now = Date.now();
        const win = (arr) => arr.filter((t) => now - t <= RATE_WINDOW_MS).length;
        return json({ last_seq, last_write_at, write_hits: win(this.writeHits), read_hits: win(this.readHits) });
      }
      if (url.pathname === "/wipe") {
        await this.ctx.storage.deleteAll();
        this.writeHits = [];
        this.readHits = [];
        return json({ ok: true });
      }
      return err(404, "not_found", "未知通道操作");
    } catch (e) {
      logLine("channel error", String(e && e.message || e));
      return err(500, "internal", "通道内部错误");
    }
  }
}

// ---------------- Worker 主入口 ----------------
function registryStub(env) {
  return env.REGISTRY.get(env.REGISTRY.idFromName("registry"));
}
async function registryCall(env, path, payload) {
  const res = await registryStub(env).fetch("https://registry" + path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
  });
  return res;
}
function channelStub(env, name) {
  return env.CHANNEL.get(env.CHANNEL.idFromName(name));
}
async function channelCall(env, name, path, payload) {
  return channelStub(env, name).fetch("https://channel" + path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
  });
}

async function handleAdmin(req, env, url) {
  const key = bearer(req);
  if (!key || !env.ADMIN_KEY) {
    logLine("admin", "no-key", "401");
    return err(401, "unauthorized", "管理接口需要主钥");
  }
  const [givenHash, realHash] = await Promise.all([sha256hex(key), sha256hex(env.ADMIN_KEY)]);
  if (!timingSafeEqual(givenHash, realHash)) {
    logLine("admin", "bad-key", "401");
    return err(401, "unauthorized", "主钥不正确");
  }
  const parts = url.pathname.split("/").filter(Boolean); // ["admin","channels",...]
  // POST /admin/channels
  if (req.method === "POST" && parts.length === 2) {
    const body = await req.json().catch(() => ({}));
    const { name, mode } = body;
    if (!NAME_RE.test(name || "")) return err(400, "bad_name", "通道名须匹配 ^[a-z0-9][a-z0-9-_]{1,63}$");
    if (mode !== "state" && mode !== "log") return err(400, "bad_mode", "mode 只能是 state 或 log");
    const accesskey = newAccessKey();
    const keyHash = await sha256hex(accesskey);
    const res = await registryCall(env, "/create", { name, mode, hmac: !!body.hmac, keyHash });
    if (res.status !== 201) return res;
    logLine("admin create done", name, "201");
    return json({ name, mode, hmac: !!body.hmac, accesskey }, 201);
  }
  // GET /admin/channels
  if (req.method === "GET" && parts.length === 2) {
    const res = await registryCall(env, "/list", {});
    const { channels } = await res.json();
    const out = [];
    for (const ch of channels) {
      const mres = await channelCall(env, ch.name, "/meta", { mode: ch.mode });
      const m = await mres.json().catch(() => ({}));
      out.push({
        name: ch.name, mode: ch.mode, hmac: ch.hmac, created_at: ch.created_at,
        last_seq: m.last_seq ?? 0, last_write_at: m.last_write_at ?? null,
        write_hits: m.write_hits ?? 0, read_hits: m.read_hits ?? 0,
      });
    }
    return json(out);
  }
  // POST /admin/channels/{name}/rotate
  if (req.method === "POST" && parts.length === 4 && parts[3] === "rotate") {
    const name = parts[2];
    const accesskey = newAccessKey();
    const keyHash = await sha256hex(accesskey);
    const res = await registryCall(env, "/rotate", { name, keyHash });
    if (res.status !== 200) return res;
    return json({ name, accesskey });
  }
  // DELETE /admin/channels/{name}
  if (req.method === "DELETE" && parts.length === 3) {
    const name = parts[2];
    const res = await registryCall(env, "/delete", { name });
    if (res.status !== 200) return res;
    await channelCall(env, name, "/wipe", {});
    return json({ ok: true, name });
  }
  return err(404, "not_found", "未知管理接口");
}

async function handleChannel(req, env, url) {
  const parts = url.pathname.split("/").filter(Boolean); // ["c","{name}"]
  const name = parts[1] || "";
  if (!NAME_RE.test(name)) return err(404, "not_found", "通道不存在");
  const res = await registryCall(env, "/get", { name });
  const { meta } = await res.json();
  if (!meta) {
    logLine("channel", name, "not-found", "404");
    return err(404, "not_found", "通道不存在");
  }
  const key = bearer(req);
  if (!key) {
    logLine("channel", name, "no-key", "401");
    return err(401, "unauthorized", "需要 accesskey（Authorization: Bearer）");
  }
  const givenHash = await sha256hex(key);
  if (!timingSafeEqual(givenHash, meta.keyHash)) {
    logLine("channel", name, "bad-key", "401");
    return err(401, "unauthorized", "accesskey 不正确");
  }
  if (req.method === "POST") {
    const rawBody = await req.text();
    if (enc.encode(rawBody).length > MAX_BODY) {
      logLine("write", name, "too-large", "413");
      return err(413, "too_large", "body 上限 64KB");
    }
    if (meta.hmac) {
      const ts = req.headers.get("X-Ts");
      const sig = req.headers.get("X-Sig");
      if (!ts || !sig) {
        logLine("write", name, "sig-missing", "403");
        return err(403, "signature_required", "该通道开启 HMAC：写请求须带 X-Ts 与 X-Sig");
      }
      const tsNum = Number(ts);
      if (!Number.isFinite(tsNum) || Math.abs(Date.now() / 1000 - tsNum) > 300) {
        logLine("write", name, "sig-stale-ts", "403");
        return err(403, "signature_stale", "X-Ts 与服务器时间偏差超过 300 秒");
      }
      const expect = await hmacHex(key, ts + "." + rawBody);
      if (!timingSafeEqual(expect, String(sig).toLowerCase())) {
        logLine("write", name, "sig-bad", "403");
        return err(403, "signature_invalid", "签名不正确");
      }
    }
    const ifSeq = req.headers.get("If-Seq");
    return channelCall(env, name, "/write", {
      name,
      mode: meta.mode,
      rawBody,
      contentType: req.headers.get("Content-Type") || "text/plain",
      ifSeq: ifSeq === null ? null : Number(ifSeq),
    });
  }
  if (req.method === "GET") {
    const sinceRaw = url.searchParams.get("since");
    const since = sinceRaw === null ? null : Number(sinceRaw);
    return channelCall(env, name, "/read", { name, mode: meta.mode, since });
  }
  return err(405, "method_not_allowed", "只支持 GET/POST");
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/" || url.pathname === "/health") {
        return json({ ok: true, service: "relay", version: 1 });
      }
      if (url.pathname.startsWith("/admin/")) return await handleAdmin(req, env, url);
      if (url.pathname.startsWith("/c/")) return await handleChannel(req, env, url);
      return err(404, "not_found", "未知路径");
    } catch (e) {
      logLine("worker error", String(e && e.message || e));
      return err(500, "internal", "内部错误");
    }
  },
};
