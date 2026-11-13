#!/usr/bin/env node
// MusePet 写状态脚本 v4（零依赖，Node >= 18）
//
// 用法：
//   node scripts/write.mjs '{"state":"working","message":"正在查资料"}'
//   node scripts/write.mjs <配置文件路径> '<状态 JSON>'
// （一个参数 = 状态 JSON；两个参数 = 第一个是 pet-channel.json / pet-bind.json 路径）
//
// 取钥优先级（默认路径）：
//   1. 本地钥文件 keys/<channel>.key 里的 writer secret（v4 正道；
//      PET_CHANNEL 环境变量可指定通道，否则取最近更新的一条）；
//   2. 包里有 pet-bind.json → 先走 /bind-agent 完成绑定再写；
//   3. 包里有 pet-channel.json → legacy 路径：用 accesskey 写
//      （legacy 通道可写；v4 通道下 accesskey 是读钥，写会 403 read_only，
//       报错会明确指出并指引改走绑定）。
//
// 输出只回 HTTP 状态与 seq，任何时候不打印 secret/accesskey 明文；
// dbg 只记 server/channel/keyLen。
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import {
  SKILL_ROOT, pickLocalSecret, listLocalSecrets, postJson,
  writeState, bindViaBindFile, isReadOnly403, READ_ONLY_GUIDANCE,
} from './petlib.mjs';

function dbg(...args) { console.error('[write]', ...args); }
function fail(msg) { console.error('写状态失败：' + msg); process.exit(1); }

function reportOk(w) {
  console.log('HTTP 200' + (w.seq !== undefined ? ' seq=' + w.seq : ''));
}

async function writeWith(server, channel, credential, stateArg, kind) {
  dbg('target server=' + server + ' channel=' + channel + ' via=' + kind + ' keyLen=' + String(credential).length);
  let w;
  try {
    w = await writeState(server, channel, credential, JSON.parse(stateArg));
  } catch (e) {
    fail('连不上中转（' + server + '）：' + e.message);
  }
  dbg('write -> HTTP ' + w.status + (w.seq !== undefined ? ' seq=' + w.seq : ''));
  if (w.status === 200) { reportOk(w); return; }
  if (isReadOnly403(w)) {
    fail('HTTP 403 read_only。' + READ_ONLY_GUIDANCE);
  }
  fail('HTTP ' + w.status + (w.text ? ' ' + w.text.slice(0, 200) : ''));
}

async function main() {
  const args = process.argv.slice(2);
  let configPath = null;
  let stateArg;
  if (args.length === 1) {
    stateArg = args[0];
  } else if (args.length === 2) {
    configPath = args[0];
    stateArg = args[1];
  } else {
    fail('用法：node scripts/write.mjs [\'<配置文件路径>\'] \'<状态 JSON>\'');
  }

  let stateObj;
  try { stateObj = JSON.parse(stateArg); } catch (e) {
    fail('状态参数不是合法 JSON：' + e.message);
  }
  if (!stateObj || typeof stateObj !== 'object' || Array.isArray(stateObj)
      || typeof stateObj.state !== 'string' || stateObj.state === '') {
    fail('状态参数必须是 JSON 对象且带非空字符串字段 state（如 {"state":"working"}）');
  }

  // ---- 显式配置文件：按内容分流（accesskey=legacy / binding_code=先绑定）
  if (configPath) {
    let cfg;
    try { cfg = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch (e) {
      fail('配置文件读不到或不是合法 JSON：' + configPath + '（' + e.message + '）');
    }
    if (cfg.binding_code) {
      const r = await bindViaBindFile(configPath, dbg);
      if (!r.ok) {
        if (r.kind === 'used_or_expired') {
          fail('绑定码已用或已过期（HTTP ' + r.status + '）。请回 MusePet App 重新点「添加 agent」导出新的 skill 包后再试。');
        }
        fail(r.message);
      }
      await writeWith(r.server, r.channel, r.secret, stateArg, 'bind-agent');
      return;
    }
    if (cfg.accesskey) {
      const server = String(cfg.server_url || '').replace(/\/+$/, '');
      if (!server || !cfg.channel) fail('通道配置缺少 server_url/channel 字段');
      await writeWith(server, cfg.channel, cfg.accesskey, stateArg, 'pet-channel-legacy');
      return;
    }
    fail('配置文件缺少 accesskey / binding_code 字段：' + configPath);
  }

  // ---- 默认路径 1：本地 writer secret
  const local = pickLocalSecret();
  if (local) {
    dbg('local secrets found=' + listLocalSecrets().length + ' picked channel=' + local.channel);
    await writeWith(local.server, local.channel, local.secret, stateArg, 'local-secret');
    return;
  }
  dbg('no local secret; falling through to package files');

  // ---- 默认路径 2：pet-bind.json 先绑定后写
  const bindPath = path.join(SKILL_ROOT, 'pet-bind.json');
  if (fs.existsSync(bindPath)) {
    const r = await bindViaBindFile(bindPath, dbg);
    if (!r.ok) {
      if (r.kind === 'used_or_expired') {
        fail('绑定码已用或已过期（HTTP ' + r.status + '）。请回 MusePet App 重新点「添加 agent」导出新的 skill 包后再试。');
      }
      fail(r.message);
    }
    await writeWith(r.server, r.channel, r.secret, stateArg, 'bind-agent');
    return;
  }

  // ---- 默认路径 3：pet-channel.json legacy
  const chanPath = path.join(SKILL_ROOT, 'pet-channel.json');
  if (fs.existsSync(chanPath)) {
    let cfg;
    try { cfg = JSON.parse(fs.readFileSync(chanPath, 'utf8')); } catch (e) {
      fail('pet-channel.json 不是合法 JSON：' + e.message);
    }
    const server = String(cfg.server_url || '').replace(/\/+$/, '');
    if (!server || !cfg.channel || !cfg.accesskey) fail('pet-channel.json 缺少 server_url/channel/accesskey 字段');
    await writeWith(server, cfg.channel, cfg.accesskey, stateArg, 'pet-channel-legacy');
    return;
  }

  fail('没有任何可用的钥：本地 keys/ 里没有 writer secret，包里也没有 pet-bind.json / pet-channel.json。先跑 scripts/claim.mjs 领取或绑定一条通道。');
}

main().catch((e) => {
  console.error('写状态失败：未预期错误：' + (e && e.message ? e.message : e));
  process.exit(1);
});
