---
name: pet-claim
description: 给 MusePet 桌面宠物接上公共中转通道（v4 凭证模型）。包里有 pet-bind.json 时走追加绑定（用一次性绑定码把本 agent 的 writer secret 绑到现成通道）；没有时运行包内脚本直领一条免费通道（secret 哈希绑定），领不到则出 bot 深链由 MusePetBot 建通道后自动完成绑定；包里的 pet-channel.json 在 v4 下只是读钥包，写状态要靠绑定。
---

# MusePet 通道领取与绑定（v4）

## 这是什么

MusePet 桌面宠物靠一条「中转通道」接收智能体的状态。官方公共中转
（pet.8529527.xyz）有一批免费通道名额，本 skill 替用户领/绑一条通道，
让本 agent 能往宠物写状态。

**v4 凭证模型（先懂这个）**：

- **writer secret 由本 agent 本地生成**，原文只存本机
  `keys/<channel>.key`（权限 600），服务端只存它的 sha256 哈希。
- **写状态必须出示 secret 原文**（`POST {server}/c/{channel}`，
  `Authorization: Bearer <secret>`），服务端比对哈希。
- **通道码退化为读钥包**：通道码里是「服务器 + 通道名 + 读钥」，复制
  只能连上看状态，**写不进去**——拿读钥写会收到 `403 read_only`。
- 所以全产品只有一种串：**通道码**（给用户粘进 App 用）。没有别的中间串。

## 先分流：看包里的文件

动手前先看本包**根目录**有什么文件，按下表分流：

| 包内文件 | 模式 | 做什么 |
|---|---|---|
| 有 `pet-bind.json` | **追加绑定** | 跑 `scripts/claim.mjs`，它读绑定文件完成绑定（见下节） |
| 什么都没有 | **领取** | 跑 `scripts/claim.mjs` 直领；领不到自动转 bot 深链（见下节） |
| 只有 `pet-channel.json` | **读钥包** | v4 通道下它只是读钥，写会 `403 read_only`；别拿它写状态，按「读钥包」一节处理。仅 legacy（老）通道还能用它直接写 |

脚本自己也会按同样的文件判断分流，`claim.mjs` / `write.mjs` 都不用你
手工搬钥。

## 追加绑定模式（包里有 pet-bind.json）

用户在 MusePet App 里点「添加 agent」后导出的 skill 包，根目录会带
`pet-bind.json`（字段：`server_url`、`channel`、`binding_code`、
`exported_at`、`note`）。绑定码一次性、约 24 小时过期、用过即废。

1. 运行：

   ```
   node scripts/claim.mjs
   ```

   脚本会：本地生成本 agent 自己的 writer secret → 算 sha256 →
   `POST /bind-agent {bindingCode, writerSecretHash, label}` 消费绑定码
   → secret 落本机 `keys/<channel>.key`（600）→ 用 secret 写一条
   验证状态。stdout 只回 HTTP 与 seq，secret 永不输出。
2. **退出码 0**：绑定完成。之后写状态直接用 `scripts/write.mjs`
   （它默认从本地钥文件取 secret）。
3. **绑定码已用/过期**（脚本会明确报这个错）：绑定码作废了，让用户回
   App 重新点「添加 agent」导出一份新包，装好后再跑。不要反复重试
   同一个旧包。
4. 幂等：本机已有这条通道的 secret 时，脚本不会重复消费绑定码，
   只做一次验证写入。

## 领取模式（包里没有 pet-bind.json）

运行：

```
node scripts/claim.mjs
```

（默认连 `https://pet.8529527.xyz`；可用环境变量 `PET_SERVER` 覆盖。）

脚本先在本机生成 writer secret 并算好 sha256，然后分三路：

### 路 1：直领成功（退出码 0）

脚本 `POST /register {writerSecretHash, writerLabel}` 领到通道，当场
用 secret 写第一条状态完成激活，然后 stdout 输出两行：摘要 + **通道码
整串**（`hatchpet1:…`，里面是读钥）。把通道码**原样**交给用户，并告诉
他：打开 MusePet App，把这一串粘进「通道」框，点连接即可。不要改动、
不要截断。

### 路 2：直领没领到 → bot 深链（脚本自动转入）

名额满（`403 quota_full`）或其它领取类失败时，脚本会生成一次性
**绑定码 B**，`POST /bind-start {bindCodeHash, writerSecretHash}` 把
哈希预登记（24 小时有效），然后输出一条深链和给用户的话术。
**把话术照原样转达给用户**（深链占位处换成脚本输出的那条）：

> 直领名额暂时没领到，点这个链接走 bot 领：<深链>
> 点链接 → 在 bot 里完成关注 → bot 会私聊发你通道码 → 粘进 App 连上 → 回来告诉我。

深链形如 `https://t.me/MusePetBot?start=bind_<B>`。B 是 secret 派生的
一次性绑定码，不是 secret 本身：链接可以转发，用过即废，也绑不出
secret。

输出深链后脚本**自动进入等待**：每约 15 秒轮询
`POST /bind-status {bindCodeHash}`，最长约 10 分钟（可用
`--poll-interval=毫秒` / `--poll-timeout=毫秒` 调）：

- 状态变 `bound`：脚本把 secret 正式落到该通道的本地钥文件，用
  secret 写一条状态验绑，报「绑定完成、通道已可写」。流程结束。
- **超时（退出码 2）**：stdout 有一行 JSON（`state` 是当前状态）。
  转告用户：完成 bot 那边步骤、把通道码粘进 App 后回来告诉你，你
  **再跑一次 `claim.mjs` 即可续上**——脚本把待绑记录（含 secret 与
  绑定码哈希）存在本地状态文件里，重跑会恢复轮询，不会重复生成
  secret 或绑定码，也不会再占名额。
- 状态 `expired`：绑定码过期，脚本已清掉待绑记录；重跑脚本重新走
  一遍即可。

### 路 3：失败（退出码 1）

stderr 有带状态码的报错，转达大意即可。特别地：报「激活失败」说明
通道订上了但第一条状态没写进去——**不要**给用户任何通道码；那条
预订 48 小时后自动过期、名额回池，网络恢复后重跑脚本重新领。

## 读钥包（包里只有 pet-channel.json）

`pet-channel.json`（字段：`server_url`、`channel`、`accesskey`、
`exported_at`、`note`）是从 App 复制/导出的现成通道配置。

- **v4 通道**：里面的 `accesskey` 是**读钥**，只能连上看状态。
  `write.mjs` 用它写会收到 `403 read_only` 并明确报错。想写状态，
  必须走绑定：让用户在 App 里点「添加 agent」导出带 `pet-bind.json`
  的新包，按追加绑定模式办。
- **legacy 通道**（v4 之前的老通道，单钥读写）：仍可按旧法直接写，
  `write.mjs` 会自动走这条路。

## 写状态（绑定/领取完成后）

```
node scripts/write.mjs '{"state":"working","message":"正在查资料"}'
```

取钥顺序（脚本自动）：本地钥文件 `keys/<channel>.key` 的 writer
secret → 包里有 `pet-bind.json` 就先绑定后写 → 包里有
`pet-channel.json` 走 legacy 路径。多个通道时可用环境变量
`PET_CHANNEL=<通道名>` 指定。输出只回 HTTP 状态与 seq。

**状态协议**（写进通道的 body）：

```json
{"state": "working", "event": null, "message": "正在查资料"}
```

- `state`（必填，常驻状态，只有三个）：`idle` 待机/在等用户；
  `working` 处理中（思考、查资料、跑工具）；`making` 在产出
  （写代码/文件、构建、生成内容）。`sleeping` 永远不要写——宠物超时
  没收到更新会自己变暗装睡，一有新写入就醒。
- `event`（一次性事件，只有两个，没有给 `null` 或省略）：`waking`
  会话开始/中断恢复时写一次；`milestone` 完成一件完整任务时写一次
  （事件动画播一遍后回落到 `state`，带 event 时 `state` 填播完后应
  停留的状态，通常是 `idle`）。
- `message`：一句人话短摘要，建议 ≤40 字；写了且 seq 变化时宠物会
  冒泡显示。任务完成时写结果摘要，被卡住时写在等什么。
- 写时机：会话开始 `{"state":"idle","event":"waking"}`；开始干活
  `{"state":"working"}`；开始产出 `{"state":"making"}`；任务完成
  `{"state":"idle","event":"milestone","message":"<结果摘要>"}`；
  等用户决策 `{"state":"idle","message":"在等：<什么>"}`。
- 节流：同一 `state` 不要重复写；连续两次写至少间隔约 10 秒；
  长任务每约 2 分钟重写一次当前 `state` 防失联变暗。

## 前置条件

无账号/凭证。只需要能联网、且有 Node ≥ 18 可运行包内脚本
（`scripts/claim.mjs`、`scripts/write.mjs`，均零依赖）。

## 纪律（务必遵守）

- **secret 纪律**：writer secret 原文**只存本机钥文件**
  （`keys/<channel>.key`，权限 600，目录 `keys/`）。不回显、不贴
  聊天、不写进日志、不提交仓库、不放进任何链接或通道码。脚本输出
  只有 HTTP 状态与 seq，dbg 日志只记 server/channel/长度。
- **激活纪律**：领取只是「预订」，48 小时内没有第一条真实状态写入
  就会作废、名额回池。脚本已把「领到立刻写第一条」做进流程，不要
  绕开脚本手工调 `/register` 只拿通道不写状态。
- **通道码按凭证对待（弱版）**：通道码含读钥，只交给用户本人粘进
  App，不写进仓库、笔记或公开场合。它被复制走最多只能看状态，
  写权限在各 agent 本地的 secret 里，复制不走。
- **一人一条**：给同一个用户领过一次就够了，不要批量领取囤积。
  同一台宠物加多个 agent 走「添加 agent」绑定，不要重复领取。
- **绑定码按一次性凭证对待**：`pet-bind.json` 与深链里的绑定码用过
  即废、约 24 小时过期；不要把绑定码原文抄进日志或笔记。
