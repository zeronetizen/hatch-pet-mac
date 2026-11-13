#!/usr/bin/env node
// MusePet 公共中转 · 通道领取/绑定脚本 v4（零依赖，Node >= 18）
//
// v4 凭证模型：writer secret 由本 agent 本地生成，原文只存本机
// keys/<channel>.key（600），服务端只存它的 sha256 哈希；通道码退化为
// 「服务器+通道名+读钥」，复制只能看、写不进去。写状态必须出示 secret 原文。
//
// 运行先分流（按包内文件判断）：
//   A. 包根目录有 pet-bind.json → 追加绑定模式：本地生成 secret，
//      POST /bind-agent 消费 App 导出的一次性绑定码，落钥后写验证状态。
//   B. 本地有待绑记录（keys/pending-bind.json）→ 恢复轮询 /bind-status，
//      不重复生成 secret/绑定码。
//   C. 其余 → 领取模式：生成 secret，POST /register 带 writerSecretHash；
//      成功组通道码交用户；失败（quota_full 或其它领取类失败）→ 生成绑定码 B，
//      POST /bind-start 预登记哈希，输出 bot 深链，轮询 /bind-status 等绑定完成。
//
// 输出约定：
//   - 成功：摘要行到 stdout，退出码 0。直领成功时第二行是通道码本体
//     （通道码只含读钥，可交用户粘进 App）；secret 永不出现在任何输出里。
//   - 绑定等待超时：stdout 一行 JSON {"ok":false,"state":<当前状态>,"pending":true}，退出码 2。
//   - 绑定码已用/过期、其它失败：stderr 明确报错与指引，退出码 1，不输出通道码。
// dbg 日志一律走 stderr，只记 server/channel/状态码/长度，永不记 secret/绑定码原文。
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import {
  SKILL_ROOT, serverFromEnv, genSecret, genBindingCode, sha256hex, agentLabel,
  saveChannelSecret, savePendingBind, loadPendingBind, clearPendingBind,
  postJson, writeStateRetry, bindViaBindFile,
} from './petlib.mjs';

function dbg(...args) { console.error('[claim]', ...args); }

function parseArgs() {
  const opts = {
    pollIntervalMs: Number(process.env.PET_POLL_INTERVAL_MS || 15000),
    pollTimeoutMs: Number(process.env.PET_POLL_TIMEOUT_MS || 600000),
  };
  for (const a of process.argv.slice(2)) {
    let m;
    if ((m = a.match(/^--poll-interval(?:-ms)?=(\d+)$/))) opts.pollIntervalMs = Number(m[1]);
    else if ((m = a.match(/^--poll-timeout(?:-ms)?=(\d+)$/))) opts.pollTimeoutMs = Number(m[1]);
    else if ((m = a.match(/^--wait(?:-ms)?=(\d+)$/))) opts.pollTimeoutMs = Number(m[1]);
  }
  if (!(opts.pollIntervalMs > 0)) opts.pollIntervalMs = 15000;
  if (!(opts.pollTimeoutMs >= 0)) opts.pollTimeoutMs = 600000;
  return opts;
}

const FIRST_STATE = { state: 'idle', event: 'waking', message: '已连接' };

// ---------- A. 追加绑定模式（pet-bind.json） ----------
async function runBindAgent(bindPath) {
  dbg('branch: bind-agent (pet-bind.json present)');
  const r = await bindViaBindFile(bindPath, dbg);
  if (!r.ok) {
    if (r.kind === 'used_or_expired') {
      console.error('绑定失败：绑定码已用或已过期（HTTP ' + r.status + ' ' + r.message + '）。'
        + '请回 MusePet App 重新点「添加 agent」导出一份新的 skill 包（会带新的 pet-bind.json），装好后再跑本脚本。');
    } else {
      console.error('绑定失败：' + r.message);
    }
    process.exit(1);
  }
  console.log('已绑定通道 ' + r.channel + (r.already ? '（本地已有 secret，跳过重复消费绑定码）' : '')
    + '，验证状态写入 HTTP ' + r.write.status + (r.write.seq !== undefined ? ' seq=' + r.write.seq : ''));
  process.exit(0);
}

// ---------- C2. bot 深链等待：轮询 /bind-status ----------
async function pollBindStatus(server, pending, secret, opts) {
  const deadline = Date.now() + opts.pollTimeoutMs;
  let lastState = 'pending';
  for (;;) {
    let r;
    try {
      r = await postJson(server, '/bind-status', { bindCodeHash: pending.bindCodeHash });
    } catch (e) {
      dbg('bind-status network error: ' + e.message);
      r = null;
    }
    if (r) {
      dbg('bind-status -> HTTP ' + r.status);
      if (r.status !== 200) {
        console.error('绑定查询失败：HTTP ' + r.status + (r.text ? ' ' + r.text.slice(0, 200) : '')
          + '。待绑记录已存本地，稍后重跑本脚本即可续上。');
        process.exit(1);
      }
      lastState = (r.json && r.json.state) || 'pending';
      dbg('bind-status state=' + lastState + (r.json && r.json.channel ? ' channel=' + r.json.channel : ''));
      if (lastState === 'bound') {
        const channel = r.json && r.json.channel;
        if (!channel) {
          console.error('绑定查询返回 bound 但缺少 channel 字段，无法落钥。待绑记录已存本地，稍后重跑本脚本续上。');
          process.exit(1);
        }
        saveChannelSecret(channel, server, secret, 'bot-bind', pending.label || agentLabel());
        clearPendingBind();
        const w = await writeStateRetry(server, channel, secret, FIRST_STATE, dbg);
        if (w.status !== 200) {
          console.error('绑定完成但验证状态写入失败：通道 ' + channel + ' HTTP ' + w.status
            + '。secret 已存本地，稍后用 scripts/write.mjs 重写一条即可。');
          process.exit(1);
        }
        console.log('绑定完成、通道已可写：通道 ' + channel + '，验证状态写入 HTTP ' + w.status
          + (w.seq !== undefined ? ' seq=' + w.seq : ''));
        process.exit(0);
      }
      if (lastState === 'expired') {
        clearPendingBind();
        console.error('绑定码已过期：这次的深链已失效。重跑本脚本会重新走一遍（直领或生成新深链）。');
        process.exit(1);
      }
      // pending / linked：继续等（linked = bot 已记下用户，通道还没建好）
    }
    if (Date.now() >= deadline) {
      console.log(JSON.stringify({ ok: false, state: lastState, pending: true }));
      console.log('还在等绑定完成（当前状态：' + lastState + '）。你完成 bot 那边的步骤、把通道码粘进 App 连上之后，回来告诉我，我再跑一次本脚本就能续上——不用重新领，secret 和绑定码都存在本地了。');
      process.exit(2);
    }
    await new Promise((res) => setTimeout(res, opts.pollIntervalMs));
  }
}

// ---------- C. 领取模式 ----------
async function runClaim(opts) {
  const server = serverFromEnv();
  dbg('branch: claim server=' + server);

  // B. 恢复：本地已有待绑记录 → 直接续轮询，不重新生成 secret/绑定码
  const pending0 = loadPendingBind();
  if (pending0 && pending0.server_url === server) {
    dbg('resume pending bind (created_at=' + (pending0.created_at || '?') + ')');
    await pollBindStatus(server, pending0, pending0.secret, opts);
    return; // pollBindStatus 内已 exit
  }
  if (pending0) clearPendingBind(); // 服务器变了，旧待绑作废

  const secret = genSecret();
  const writerSecretHash = sha256hex(secret);
  const label = agentLabel();
  dbg('generated writer secret secretLen=' + secret.length + ' hashLen=' + writerSecretHash.length + ' label=' + label);

  // 1. 直领：POST /register 带 writerSecretHash
  let regRes;
  try {
    regRes = await postJson(server, '/register', { writerSecretHash, writerLabel: label });
  } catch (e) {
    console.error('领取失败：连不上公共中转（' + server + '）：' + e.message);
    process.exit(1);
  }
  dbg('register -> HTTP ' + regRes.status);

  if ((regRes.status === 201 || regRes.status === 200) && regRes.json && regRes.json.channel) {
    const channel = regRes.json.channel;
    const readKey = regRes.json.key;
    saveChannelSecret(channel, server, secret, 'register', label);
    dbg('register ok channel=' + channel + ' secret saved (key file 600)');
    const w = await writeStateRetry(server, channel, secret, FIRST_STATE, dbg);
    if (w.status !== 200) {
      console.error('激活失败：通道 ' + channel + ' 已领到但第一条状态没写进去（HTTP ' + w.status + '）。'
        + '先不要把任何东西粘进 App；这条预订会在 48 小时后自动过期、名额回池，网络恢复后重跑本脚本重新领即可。');
      process.exit(1);
    }
    dbg('activated channel=' + channel + ' seq=' + (w.seq !== undefined ? w.seq : '?'));
    if (!readKey) {
      console.error('领取成功但服务器没有返回读钥（key 字段），无法组通道码。通道 ' + channel + ' 已绑定本机 secret，可直接用 scripts/write.mjs 写状态；通道码请向服务端确认。');
      process.exit(1);
    }
    const pairing = 'hatchpet1:' + Buffer.from(
      JSON.stringify({ v: 1, server, channel, key: readKey }),
      'utf8',
    ).toString('base64url');
    console.log('已领取并激活通道 ' + channel + '，把下面这一整串复制下来、粘进 MusePet App 的「通道」框：');
    console.log(pairing);
    process.exit(0);
  }

  // 2. 直领失败（quota_full 或其它领取类失败）→ bot 深链分支
  const errName = regRes.json && regRes.json.error ? String(regRes.json.error) : '';
  dbg('register failed branch: status=' + regRes.status + ' error=' + (errName || '(none)') + ' -> bind-start');
  const B = genBindingCode();
  const bindCodeHash = sha256hex(B);
  let bs;
  try {
    bs = await postJson(server, '/bind-start', { bindCodeHash, writerSecretHash });
  } catch (e) {
    console.error('领取失败且绑定预登记也连不上中转（' + server + '）：' + e.message);
    process.exit(1);
  }
  dbg('bind-start -> HTTP ' + bs.status);
  if (bs.status !== 200 && bs.status !== 201) {
    console.error('绑定预登记失败：HTTP ' + bs.status + (bs.text ? ' ' + bs.text.slice(0, 200) : '') + '。稍后重跑本脚本再试。');
    process.exit(1);
  }
  const pending = {
    server_url: server,
    bindCodeHash,
    writerSecretHash,
    label,
    created_at: new Date().toISOString(),
    note: 'bot-bind pending; secret in pending-bind.key (600)',
  };
  savePendingBind(pending, secret);
  dbg('pending bind saved (hashes only in json; secret in key file 600)');

  const deepLink = 'https://t.me/MusePetBot?start=bind_' + B;
  console.log('直领没领到（' + (errName || 'HTTP ' + regRes.status) + '），改走 bot 引导。把下面这条链接发给用户：');
  console.log(deepLink);
  console.log('给用户的话：点这个链接 → 在 bot 里完成关注 → bot 会私聊发你一条通道码 → 把通道码粘进 MusePet App 的「通道」框连上 → 回来告诉我一声，我这边会自动等绑定完成。');
  await pollBindStatus(server, pending, secret, opts);
}

async function main() {
  const opts = parseArgs();
  dbg('start pollIntervalMs=' + opts.pollIntervalMs + ' pollTimeoutMs=' + opts.pollTimeoutMs);
  const bindPath = path.join(SKILL_ROOT, 'pet-bind.json');
  if (fs.existsSync(bindPath)) {
    await runBindAgent(bindPath);
    return;
  }
  await runClaim(opts);
}

main().catch((e) => {
  console.error('失败：未预期错误：' + (e && e.message ? e.message : e));
  process.exit(1);
});
