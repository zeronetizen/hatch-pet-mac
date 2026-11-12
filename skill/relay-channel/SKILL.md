---
name: relay-channel-setup
description: 在自己的 Cloudflare 账号上一键部署一套 relay 通用数据通道服务（Worker + Durable Objects，state/log 双模式、读写同一 accesskey、可选 HMAC 签名校验），并建好第一条通道。当用户想自建通道服务器、不想让应用数据经过别人的服务器、或需要一条「能写能查、内容自定义」的中转通道时使用。
---

# relay 通用通道 · 一键部署

## 这是什么

一条极简的通用数据通道：给通道起个名字，就能往里写任意 JSON（或文本，≤64KB），
任何持有该通道 accesskey 的客户端都能读。两种模式：

- **state**：只保留最新一条（状态同步，如桌面宠物的当前状态）；
- **log**：追加保留最近 100 条，按序号增量拉取（事件/通知流）。

读写共用同一把 accesskey（服务端只存它的 SHA-256 哈希）；可按通道开启 HMAC
签名校验（写请求带时间戳签名，防篡改与重放）；每通道限频（写 60/分、读 600/分）。

服务端是单个 Cloudflare Worker + 两个 Durable Object 类，无数据库要维护，
Cloudflare 免费额度对个人量级足够。

## 前置条件（缺一不可，先逐项确认）

1. **自己的 Cloudflare 账号**，且已启用 workers.dev 子域
   （Dashboard → Workers & Pages 打开一次即可生成子域）。
2. **该账号的 API token**，权限至少包含：Account → Workers Scripts → Edit
   （部署脚本、设置 secret、开子域都走它）。
3. token 必须走 **Muse 的安全凭证流程**注册成连接器（本 skill 按
   `custom.cloudflare` 连接器 + `dynamic_credentials` surrogate 取值，
   见 assets/deploy.py 顶部）。**绝不把 token 明文粘贴到聊天、代码或文件里**；
   没有这个连接器时，先按 custom-connector-setup 的流程建好再继续。
4. 本机有 python3 与 node（部署与管理脚本用）。

## 执行步骤

1. 把本 skill 的 `assets/` 整个拷到一个工作目录，例如 `~/workspace/relay-channel/`，
   后续命令都在该目录执行。目录结构：worker.js（服务端）、deploy.py（部署）、
   relay-admin.mjs（通道管理）、relay.mjs（通道读写）。
2. （可选）若 token 能看到多个账号，设 `CF_ACCOUNT_ID=<账号ID>`；
   不设时 deploy.py 会自动取账号列表第一个。
3. 部署：`python3 deploy.py`
   - 脚本在本机生成主钥（32 字节随机），落 `keys/admin.key`（权限 600），
     并经 API 设为 Worker 的 secret `ADMIN_KEY`；全程只打印钥长度、不打印原文；
   - 上传 Worker（含 Durable Objects 绑定与 SQLite 迁移）、开启 workers.dev 子域；
   - 结尾打印你的服务地址 `https://relay.<你的子域>.workers.dev/`，记下它。
   - 重复运行是更新（幂等），不会换主钥、不会丢通道数据。
4. 建第一条通道（把地址换成第 3 步的）：
   `RELAY_URL=https://relay.<你的子域>.workers.dev node relay-admin.mjs create my-first-channel --mode=state`
   - 默认开启 HMAC；不要签名就加 `--no-hmac`；事件流用 `--mode=log`；
   - 返回的 accesskey 由脚本直接写进 `keys/my-first-channel.key`（600），
     只在终端报长度。**不要 cat 它、不要贴到聊天里**。
5. 验收（见下节）通过后，把服务器地址交给你的客户端应用配置；
   accesskey 通过安全方式给到客户端（例如在应用设置里由用户本人粘贴，
   应用应存系统钥匙串，不要硬编码进公开代码或安装包）。

## 随包配置 pet-channel.json（可选，来自宠物 App 导出）

有些分发包会在包根目录多一个 `pet-channel.json`——那是从宠物设置导出的现成
通道配置（由 HatchPet 设置面板的「导出 skill 包」在导出时生成），字段：
`server_url`、`channel`、`accesskey`、`exported_at`、`note`。

- **按凭证对待**：里面的 accesskey 是明文通道钥。文件落盘权限设 600；不贴到
  聊天、不写进日志、不提交到任何仓库。拿到它的人可读写这条通道，只在信任的
  人之间传递。
- **接收方直接用这条通道**（不想自建服务器时）：把钥写进脚本的钥目录后即可
  用包内脚本读写。例如在 assets 拷出的工作目录里，先把 `pet-channel.json`
  里的 accesskey 落成钥文件（由 Muse 操作时同样不要回显钥原文）：
  `mkdir -p keys && umask 077`，把 accesskey 写入 `keys/<channel>.key`（600）；
  然后 `RELAY_URL=<server_url> node relay.mjs read <channel>` 读、
  `RELAY_URL=<server_url> node relay.mjs write <channel> '<json>' --hmac` 写
  （通道开了 HMAC 才需要 `--hmac`，不确定就带上）。
- **想用自己的服务器**：无视 `pet-channel.json`，按上面「执行步骤」部署自己
  的服务；部署完成后建议删掉 `pet-channel.json`，避免两条通道混淆。

## 钥的保存规矩（硬性）

- 主钥与通道钥只落本机 `keys/` 目录（目录 700、文件 600），脚本之外不复制；
- 任何日志、截图、聊天、提交里都不出现钥原文，只报「通道名 + 钥长度 + 状态」；
- 服务端只存通道钥的哈希，丢了钥只能用管理脚本轮换：
  `RELAY_URL=... node relay-admin.mjs rotate <通道名>`（旧钥立即失效，数据保留）；
- 一个业务一条通道一把钥，互不连累。

## 验收方法

在部署目录执行（RELAY_URL 同上）：

1. 写：`node relay.mjs write my-first-channel '{"hello":"relay"}' --hmac`
   （通道开了 HMAC 就带 --hmac），应回 `HTTP 200 {"seq":1,...}`；
2. 读：`node relay.mjs read my-first-channel` 应回 seq=1 与刚写的内容；
3. 增量：`node relay.mjs read my-first-channel --since=1` 应回 204（无变化）；
4. 错钥应被拒：随便改一个字符的钥请求应回 401（可用 curl 手工验，钥从文件读入变量，不要写进命令历史明文长串——或跳过此步）；
5. 管理面：`node relay-admin.mjs list` 能看到通道与 last_seq=1。

四项全过即部署完成。之后客户端只需知道三样：服务器地址、通道名、accesskey。

## 接口速览（给客户端开发）

- 写：`POST /c/{name}`，头 `Authorization: Bearer <accesskey>`，body 任意（≤64KB）；
  开 HMAC 的通道还要 `X-Ts: <秒>` 与 `X-Sig: hex(HMAC-SHA256(key, "<X-Ts>.<原始body>"))`，
  时间戳偏差超 300 秒拒绝（403）；可选 `If-Seq: N` 条件写，不符回 409。
- 读：`GET /c/{name}?since=N`，只认 Bearer 钥。state 模式无变化回 204；
  log 模式回 `{seq, items:[...]}` 增量列表。
- 错误码：401 钥不对/缺失，403 签名问题，404 通道不存在，409 条件写冲突，
  413 超 64KB，429 超限频。
