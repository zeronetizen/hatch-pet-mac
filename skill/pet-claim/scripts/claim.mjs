#!/usr/bin/env node
// HatchPet 公共中转 · 免费通道领取脚本（零依赖，Node >= 18）
//
// 流程：
//   1. POST /register 向公共中转领取一条免费通道（预订）
//   2. 拿到 key 后立刻 POST /c/<channel> 写第一条状态，完成激活
//      （预订只有 48 小时窗口，第一条状态写入才算正式占住名额）
//   3. 把配对三件套组装成免费通道码 hatchpet1:<base64url(JSON)> 输出到 stdout，
//      交给用户粘进 HatchPet App
//
// 输出约定（智能体按这个解析）：
//   - 成功：stdout 两行 —— 第一行人类可读摘要（只含通道名，不含 key），
//     第二行就是免费通道码本体；退出码 0。
//   - 满员（403 quota_full）：stdout 先打一行 JSON（{"ok":false,"state":"full",...}），
//     后面跟给用户看的双路引导话术；退出码 2。
//   - 其他失败：stderr 报错（带 HTTP 状态码），退出码 1，不输出免费通道码。
// dbg 日志一律走 stderr，且任何时候都不打印 key 明文（最终免费通道码除外，
// 那是它唯一的出口）。
'use strict';

const SERVER = (process.env.PET_SERVER || 'https://pet.8529527.xyz').replace(/\/+$/, '');

function dbg(...args) { console.error('[claim]', ...args); }

async function main() {
  dbg('start server=' + SERVER);

  // ---- 1. 领取（预订）
  let regRes;
  try {
    regRes = await fetch(SERVER + '/register', { method: 'POST' });
  } catch (e) {
    console.error('领取失败：连不上公共中转（' + SERVER + '）：' + e.message);
    process.exit(1);
  }
  dbg('register -> HTTP ' + regRes.status);

  if (regRes.status === 403) {
    let body = {};
    try { body = await regRes.json(); } catch (e) { /* 忽略，走通用满员话术 */ }
    if (body.error === 'quota_full') {
      dbg('branch: quota_full');
      console.log(JSON.stringify({
        ok: false,
        state: 'full',
        error: 'quota_full',
        paths: Array.isArray(body.paths) ? body.paths : ['bot', 'selfhost'],
      }));
      console.log('公共中转的免费名额已经领完了，还有两条路可以拿到通道：');
      console.log('1）去 Telegram 找 @MusePetBot：按它的任务墙关注几个频道，bot 会发你一个一次性兑换码，回到 MusePet App 引导页填入兑换码即可。');
      console.log('2）自建中转：用 relay-channel-setup skill，在你自己的 Cloudflare 上部署一套专属中转，数据完全自持，部署完同样会得到一条通道和自建通道码。');
      process.exit(2);
    }
    console.error('领取失败：HTTP 403 ' + JSON.stringify(body));
    process.exit(1);
  }

  if (regRes.status !== 201 && regRes.status !== 200) {
    let text = '';
    try { text = await regRes.text(); } catch (e) { /* ignore */ }
    console.error('领取失败：HTTP ' + regRes.status + (text ? ' ' + text.slice(0, 200) : ''));
    process.exit(1);
  }

  let reg;
  try { reg = await regRes.json(); } catch (e) {
    console.error('领取失败：服务器返回的不是合法 JSON（HTTP ' + regRes.status + '）');
    process.exit(1);
  }
  const channel = reg.channel;
  const channelKey = reg.key;
  if (!channel || !channelKey) {
    console.error('领取失败：服务器返回缺少 channel/key 字段');
    process.exit(1);
  }
  dbg('register ok channel=' + channel + ' keyLen=' + String(channelKey).length);

  // ---- 2. 当场写第一条状态，完成激活（失败重试，避免预订白占窗口）
  const firstState = { state: 'idle', event: 'waking', message: '已连接' };
  let writeOk = false;
  let lastErr = '';
  for (let attempt = 1; attempt <= 3 && !writeOk; attempt++) {
    try {
      const w = await fetch(SERVER + '/c/' + encodeURIComponent(channel), {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + channelKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(firstState),
      });
      dbg('activate write attempt ' + attempt + ' -> HTTP ' + w.status);
      if (w.status === 200) { writeOk = true; break; }
      lastErr = 'HTTP ' + w.status;
    } catch (e) {
      lastErr = e.message;
      dbg('activate write attempt ' + attempt + ' error: ' + e.message);
    }
    if (!writeOk && attempt < 3) await new Promise((r) => setTimeout(r, 800 * attempt));
  }
  if (!writeOk) {
    // 不输出免费通道码：没激活的通道粘进 App 也不会动。这条预订会在 48 小时后
    // 自动过期、名额回池，不惩罚，稍后重跑本脚本即可。
    console.error('激活失败：通道 ' + channel + ' 已预订但第一条状态没写进去（' + lastErr + '）。'
      + '先不要把任何东西粘进 App；稍后网络恢复后重跑本脚本重新领取即可。');
    process.exit(1);
  }
  dbg('activated channel=' + channel);

  // ---- 3. 组装免费通道码并输出（key 只在这里出现一次）
  const pairing = 'hatchpet1:' + Buffer.from(
    JSON.stringify({ v: 1, server: SERVER, channel, key: channelKey }),
    'utf8',
  ).toString('base64url');
  console.log('已领取并激活通道 ' + channel + '，把下面这一整串复制下来、粘进 MusePet App 的「通道」框：');
  console.log(pairing);
}

main().catch((e) => {
  console.error('领取失败：未预期错误：' + (e && e.message ? e.message : e));
  process.exit(1);
});
