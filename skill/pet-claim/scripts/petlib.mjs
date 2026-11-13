// MusePet pet-claim 共享库（零依赖，Node >= 18）
// claim.mjs 与 write.mjs 共用：secret 生成/哈希、本地钥文件存取、
// 绑定（/bind-agent）、写状态（POST /c/<channel>）。
//
// 钥纪律：writer secret 原文只存本机 keys/<channel>.key（权限 600）；
// 任何函数都不把 secret 打到 stdout/stderr/log，只报长度。
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const SKILL_ROOT = path.join(SCRIPT_DIR, '..');
export const KEYS_DIR = path.join(SKILL_ROOT, 'keys');
export const DEFAULT_SERVER = 'https://pet.8529527.xyz';

export function serverFromEnv() {
  return (process.env.PET_SERVER || DEFAULT_SERVER).replace(/\/+$/, '');
}

export function genSecret() {
  // 32 字节随机 → base64url（43 字符），量级与现行通道钥一致
  return crypto.randomBytes(32).toString('base64url');
}

export function genBindingCode() {
  return crypto.randomBytes(32).toString('base64url');
}

export function sha256hex(s) {
  return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex');
}

export function agentLabel() {
  const raw = process.env.PET_AGENT_LABEL || os.hostname() || 'agent';
  const clean = String(raw).split('.')[0].replace(/[^A-Za-z0-9_-]+/g, '-').slice(0, 32);
  return clean || 'agent';
}

// ---------- 本地钥文件 ----------
// 约定：keys/<channel>.key 存 secret 原文（600）；
//       keys/<channel>.json 记 {channel, server_url, boundVia, label, updated_at}；
//       keys/pending-bind.key / keys/pending-bind.json 存 bot 深链待绑记录（可恢复轮询）。

export function ensureKeysDir() {
  fs.mkdirSync(KEYS_DIR, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(KEYS_DIR, 0o700); } catch (e) { /* 尽力 */ }
}

function writeSecretFile(file, secret) {
  ensureKeysDir();
  fs.writeFileSync(file, secret + '\n', { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch (e) { /* 尽力 */ }
}

function writeJsonFile(file, obj) {
  ensureKeysDir();
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch (e) { /* 尽力 */ }
}

export function saveChannelSecret(channel, server, secret, boundVia, label) {
  writeSecretFile(path.join(KEYS_DIR, channel + '.key'), secret);
  writeJsonFile(path.join(KEYS_DIR, channel + '.json'), {
    channel,
    server_url: server,
    boundVia,
    label: label || null,
    updated_at: new Date().toISOString(),
  });
}

export function loadChannelSecret(channel) {
  const keyFile = path.join(KEYS_DIR, channel + '.key');
  const metaFile = path.join(KEYS_DIR, channel + '.json');
  let secret;
  try { secret = fs.readFileSync(keyFile, 'utf8').trim(); } catch (e) { return null; }
  if (!secret) return null;
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')); } catch (e) { /* 元数据缺失可容忍 */ }
  return { channel, secret, server: (meta.server_url || serverFromEnv()).replace(/\/+$/, ''), boundVia: meta.boundVia || null };
}

// 列出全部本地钥（按文件修改时间新→旧）；PET_CHANNEL 环境变量可指定通道。
export function listLocalSecrets() {
  let names = [];
  try { names = fs.readdirSync(KEYS_DIR); } catch (e) { return []; }
  const out = [];
  for (const n of names) {
    if (!n.endsWith('.key') || n === 'pending-bind.key') continue;
    const channel = n.slice(0, -4);
    const rec = loadChannelSecret(channel);
    if (!rec) continue;
    let mtime = 0;
    try { mtime = fs.statSync(path.join(KEYS_DIR, n)).mtimeMs; } catch (e) { /* ignore */ }
    out.push({ ...rec, mtime });
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

export function pickLocalSecret() {
  const all = listLocalSecrets();
  if (all.length === 0) return null;
  const want = process.env.PET_CHANNEL;
  if (want) return all.find((r) => r.channel === want) || null;
  return all[0];
}

export function savePendingBind(pending, secret) {
  writeSecretFile(path.join(KEYS_DIR, 'pending-bind.key'), secret);
  writeJsonFile(path.join(KEYS_DIR, 'pending-bind.json'), pending);
}

export function loadPendingBind() {
  let meta;
  try { meta = JSON.parse(fs.readFileSync(path.join(KEYS_DIR, 'pending-bind.json'), 'utf8')); } catch (e) { return null; }
  let secret;
  try { secret = fs.readFileSync(path.join(KEYS_DIR, 'pending-bind.key'), 'utf8').trim(); } catch (e) { return null; }
  if (!meta || !meta.bindCodeHash || !secret) return null;
  return { ...meta, secret };
}

export function clearPendingBind() {
  for (const n of ['pending-bind.key', 'pending-bind.json']) {
    try { fs.unlinkSync(path.join(KEYS_DIR, n)); } catch (e) { /* 不存在即可 */ }
  }
}

// ---------- HTTP ----------

export async function postJson(server, p, body) {
  const res = await fetch(server + p, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let text = '';
  try { text = await res.text(); } catch (e) { /* ignore */ }
  let json = null;
  try { json = JSON.parse(text); } catch (e) { /* 非 JSON 响应 */ }
  return { status: res.status, text, json };
}

// 写一条状态；credential 为 writer secret 原文（v4）或 legacy 通道钥。
// 返回 {status, seq, text, json}，不抛网络外异常由调用方处理文本。
export async function writeState(server, channel, credential, stateObj) {
  const res = await fetch(server + '/c/' + encodeURIComponent(channel), {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + credential,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(stateObj),
  });
  let text = '';
  try { text = await res.text(); } catch (e) { /* ignore */ }
  let json = null;
  try { json = JSON.parse(text); } catch (e) { /* ignore */ }
  const seq = json && typeof json.seq === 'number' ? json.seq : undefined;
  return { status: res.status, seq, text, json };
}

// 带重试的激活/验证写入（领到通道后立刻写第一条才算激活/绑实）
export async function writeStateRetry(server, channel, credential, stateObj, dbg, attempts = 3) {
  let last = { status: 0, text: '' };
  for (let i = 1; i <= attempts; i++) {
    try {
      last = await writeState(server, channel, credential, stateObj);
      dbg('write attempt ' + i + ' channel=' + channel + ' -> HTTP ' + last.status);
      if (last.status === 200) return last;
    } catch (e) {
      last = { status: 0, text: e.message };
      dbg('write attempt ' + i + ' channel=' + channel + ' error: ' + e.message);
    }
    if (i < attempts) await new Promise((r) => setTimeout(r, 800 * i));
  }
  return last;
}

// 消费 pet-bind.json 的绑定码完成追加绑定。
// 成功：{ok:true, server, channel, secret, write}（secret 已落本地钥文件并写过验证状态）
// 失败：{ok:false, kind:'used_or_expired'|'error', status, message}
export async function bindViaBindFile(bindFilePath, dbg) {
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(bindFilePath, 'utf8')); } catch (e) {
    return { ok: false, kind: 'error', status: 0, message: 'pet-bind.json 读不到或不是合法 JSON：' + e.message };
  }
  const server = String(cfg.server_url || serverFromEnv()).replace(/\/+$/, '');
  const channel = cfg.channel;
  const bindingCode = cfg.binding_code;
  if (!channel || !bindingCode) {
    return { ok: false, kind: 'error', status: 0, message: 'pet-bind.json 缺少 channel/binding_code 字段' };
  }
  dbg('bind-agent target server=' + server + ' channel=' + channel);

  // 幂等：本机已有这条通道的 secret 就不重复消费绑定码，直接验写。
  const existing = loadChannelSecret(channel);
  if (existing && existing.server === server) {
    dbg('bind-agent: local secret already present channel=' + channel + ' keyLen=' + existing.secret.length);
    const w = await writeStateRetry(server, channel, existing.secret, { state: 'idle', event: 'waking', message: '已连接' }, dbg);
    if (w.status === 200) return { ok: true, already: true, server, channel, secret: existing.secret, write: w };
    return { ok: false, kind: 'error', status: w.status, message: '本地已有该通道 secret 但验证写入失败：HTTP ' + w.status };
  }

  const secret = genSecret();
  const writerSecretHash = sha256hex(secret);
  const label = agentLabel();
  dbg('bind-agent label=' + label + ' secretLen=' + secret.length + ' hashLen=' + writerSecretHash.length);
  let r;
  try {
    r = await postJson(server, '/bind-agent', { bindingCode, writerSecretHash, label });
  } catch (e) {
    return { ok: false, kind: 'error', status: 0, message: '连不上中转（' + server + '）：' + e.message };
  }
  dbg('bind-agent -> HTTP ' + r.status);
  if (r.status !== 200 && r.status !== 201) {
    const errStr = (r.json && (r.json.error || r.json.message)) || r.text.slice(0, 200);
    const s = String(errStr).toLowerCase();
    if (r.status === 410 || s.includes('expired') || s.includes('used') || s.includes('consumed') || s.includes('invalid')) {
      return { ok: false, kind: 'used_or_expired', status: r.status, message: String(errStr) };
    }
    return { ok: false, kind: 'error', status: r.status, message: 'HTTP ' + r.status + ' ' + String(errStr) };
  }
  saveChannelSecret(channel, server, secret, 'bind-agent', label);
  dbg('bind-agent ok channel=' + channel + ' secret saved (key file 600)');
  const w = await writeStateRetry(server, channel, secret, { state: 'idle', event: 'waking', message: '已连接' }, dbg);
  if (w.status !== 200) {
    return { ok: false, kind: 'error', status: w.status, message: '绑定已完成但验证状态写入失败：HTTP ' + w.status + '（secret 已存本地，稍后用 write.mjs 重写即可）' };
  }
  return { ok: true, server, channel, secret, write: w };
}

export function isReadOnly403(r) {
  const e = r && r.json && r.json.error ? String(r.json.error) : '';
  return r && r.status === 403 && (e === 'read_only' || String(r.text || '').includes('read_only'));
}

export const READ_ONLY_GUIDANCE = '这把钥是读钥：v4 通道的通道码内钥只能读、写状态会 403 read_only。'
  + '写状态必须用绑定 agent 的 writer secret——请让主人在 App 里点「添加 agent」导出带 pet-bind.json 的 skill 包，'
  + '装好后先跑 scripts/claim.mjs 完成绑定（secret 只存本机），再用 scripts/write.mjs 写状态。';
