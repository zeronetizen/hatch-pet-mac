#!/usr/bin/env node
// MusePet 写状态脚本（零依赖，Node >= 18）
//
// 用途（多对一）：把状态写进 pet-channel.json 里的现成通道——这条通道已经
// 在用户的 MusePet App 里连好了，写进去宠物立刻跟随。不领取新通道、
// 不需要其他凭证。
//
// 用法：
//   node scripts/write.mjs '{"state":"working","message":"正在查资料"}'
//   node scripts/write.mjs <pet-channel.json 路径> '<状态 JSON>'
// （一个参数 = 状态 JSON，配置默认取包根目录的 pet-channel.json；
//   两个参数 = 第一个是配置文件路径、第二个是状态 JSON）
//
// 行为：POST {server_url}/c/{channel}，Authorization: Bearer <accesskey>，
// body 为参数传入的状态 JSON。只向 stdout 输出 HTTP 状态与 seq；
// 任何时候（stdout/stderr/日志）都不打印 accesskey 明文。
// 退出码：0 = 写入成功（HTTP 200）；1 = 失败（参数/配置/网络/非 200）。
'use strict';

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG = path.join(SCRIPT_DIR, '..', 'pet-channel.json');

function dbg(...args) { console.error('[write]', ...args); }

function fail(msg) {
  console.error('写状态失败：' + msg);
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  let configPath = DEFAULT_CONFIG;
  let stateArg;
  if (args.length === 1) {
    stateArg = args[0];
  } else if (args.length === 2) {
    configPath = args[0];
    stateArg = args[1];
  } else {
    fail('用法：node scripts/write.mjs [\'<pet-channel.json 路径>\'] \'<状态 JSON>\'');
  }

  // ---- 状态参数：必须是带 state 字符串的 JSON 对象（原文照发，不重组）
  let stateObj;
  try { stateObj = JSON.parse(stateArg); } catch (e) {
    fail('状态参数不是合法 JSON：' + e.message);
  }
  if (!stateObj || typeof stateObj !== 'object' || Array.isArray(stateObj)
      || typeof stateObj.state !== 'string' || stateObj.state === '') {
    fail('状态参数必须是 JSON 对象且带非空字符串字段 state（如 {"state":"working"}）');
  }

  // ---- 读配置：pet-channel.json（字段 server_url/channel/accesskey/...）
  let cfgRaw;
  try { cfgRaw = fs.readFileSync(configPath, 'utf8'); } catch (e) {
    fail('读不到通道配置 ' + configPath + '（' + e.message + '）。包里没有 pet-channel.json 时先走领取流程（scripts/claim.mjs），或把配置文件路径作为第一个参数传入');
  }
  let cfg;
  try { cfg = JSON.parse(cfgRaw); } catch (e) {
    fail('通道配置不是合法 JSON：' + e.message);
  }
  const server = String(cfg.server_url || '').replace(/\/+$/, '');
  const channel = cfg.channel;
  const accesskey = cfg.accesskey;
  if (!server || !channel || !accesskey) {
    fail('通道配置缺少 server_url/channel/accesskey 字段');
  }
  dbg('target server=' + server + ' channel=' + channel + ' keyLen=' + String(accesskey).length);

  // ---- 写状态（公共中转写接口：POST /c/<channel>，Bearer 钥）
  let res;
  try {
    res = await fetch(server + '/c/' + encodeURIComponent(channel), {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + accesskey,
        'Content-Type': 'application/json',
      },
      body: stateArg,
    });
  } catch (e) {
    fail('连不上中转（' + server + '）：' + e.message);
  }
  let text = '';
  try { text = await res.text(); } catch (e) { /* 忽略，状态码已足够 */ }
  let seq;
  try {
    const body = JSON.parse(text);
    if (body && typeof body.seq === 'number') seq = body.seq;
  } catch (e) { /* 无 seq 可报，不算失败 */ }
  dbg('write -> HTTP ' + res.status + (seq !== undefined ? ' seq=' + seq : ''));
  if (res.status !== 200) {
    console.error('写状态失败：HTTP ' + res.status + (text ? ' ' + text.slice(0, 200) : ''));
    process.exit(1);
  }
  console.log('HTTP 200' + (seq !== undefined ? ' seq=' + seq : ''));
}

main().catch((e) => {
  console.error('写状态失败：未预期错误：' + (e && e.message ? e.message : e));
  process.exit(1);
});
