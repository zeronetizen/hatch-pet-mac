# Hatch 悬浮宠物 · Mac 版（v0.11：云形修匀 + 按状态自定义形象 + GitHub 自助更新）

把 Muse 的 5 个日常状态动画做成 macOS 桌面悬浮宠物：无边框透明窗口、始终置顶、
跨所有桌面空间，播放时用 GPU 着色器实时把视频白底抠成透明（与 Android v0.2 同方案同参数）。

**v0.2 起接入通用通道（relay）**：在「设置…」里填服务器地址、通道名与 accesskey
（钥存本机文件，权限 600；v0.6 起不用系统钥匙串），宠物即按间隔轮询通道状态（state / 一次性事件 / 状态消息），
状态消息会在宠物上方冒泡显示；未配置钥时自动退回纯本地手动模式。通道服务可自建：
仓库 `skill/relay-channel/` 是给 Muse 的一键部署 skill，装上后一句话即可在自己的
Cloudflare 上部署一套同样的通道服务。

分支策略：`main` 分支在正式就绪前保持只有 README，开发全部在 `dev` 分支，
构建也只由 `dev` 的推送（或手动 Run workflow）触发。

## 结构

```
mac/
├── Package.swift                  SwiftPM 工程（swift-tools 5.9，macOS 13+，零三方依赖）
├── Sources/HatchPet/
│   ├── main.swift                 入口（accessory 应用）
│   ├── AppDelegate.swift          装配、窗口位置/尺寸/穿透持久化、系统事件观察者
│   ├── PetPanel.swift             NSPanel 悬浮窗（borderless/floating/全空间）
│   ├── PetVideoRenderer.swift     AVPlayer + VideoOutput + Metal 抠像；失败回退 AVPlayerLayer
│   ├── PetViews.swift             内容视图（拖动移窗、点击判定）
│   ├── StateMachine.swift         状态机（2 秒防抖、一次性回落、本地事件不打断忙碌）
│   ├── PetState.swift             5 个状态定义（idle/working/making 循环，waking/milestone 一次性）
│   ├── ResourceLocator.swift      资源定位：先 Bundle.main，再 Bundle.module
│   ├── StatusMenuController.swift 菜单栏图标与菜单（通道状态/最新消息/设置入口）
│   ├── ChannelSettings.swift      通道配置（UserDefaults；钥走本机钥文件）
│   ├── KeyFileStore.swift         accesskey 的本机文件存取（App Support/HatchPet/keys，600）
│   ├── ChannelPoller.swift        通道轮询（since 增量、错误指数退避、睡眠暂停）
│   ├── BubbleController.swift     状态消息气泡（宠物上方、6 秒自动消失、点击关闭）
│   ├── SettingsWindowController.swift 设置窗口（字段/测试连接/详细说明）
│   ├── PetLog.swift               全量日志（~/Library/Logs/HatchPet.log + NSLog）
│   └── Resources/                 5 个原始 mp4（480×480 H.264，未重编码）
├── Packaging/Info.plist           LSUIElement、com.nonzero.hatchpet.mac、最低系统 13.0
├── assemble_app.sh                swift build universal → 组装 .app → ad-hoc 签名 → zip
└── .github/workflows/build.yml    push main / 手动触发 → macos-latest 构建 → artifact
```

## 构建方式

本机（Linux）编不了 macOS 应用，走 GitHub Actions 云端 Mac：

1. 把本目录内容推到公开仓的 `dev` 分支（自动触发），或在仓库 Actions 页手动 **Run workflow**；
2. 构建完成后在该次运行的 **Artifacts** 区下载 `HatchPet-mac`（内含 `HatchPet-mac.zip`）。

本地有 Mac 的话也可以直接：`bash assemble_app.sh`（需 Xcode 命令行工具），产物同名。

## 安装

1. 解压 `HatchPet-mac.zip` 得到 `HatchPet.app`，拖到「应用程序」或任意位置；
2. 首次打开会被 Gatekeeper 拦（ad-hoc 签名、自用未公证）：**右键点 App → 打开 → 再点「打开」**；
   或终端执行 `xattr -dr com.apple.quarantine /path/to/HatchPet.app` 后再双击；
3. 启动后宠物出现在主屏右下偏上，菜单栏出现爪印图标；没有 Dock 图标是正常的（LSUIElement）。

## 操作

- **拖动**：按住宠物拖到任意位置，松手自动记住位置，下次启动恢复；
- **菜单栏菜单**：切换状态（待机/办公/做东西/苏醒/里程碑，当前状态打勾）、
  尺寸（100/120/160/200/240pt）、触摸穿透、隐藏/显示、设置…、退出；
  菜单顶部还会显示通道连接状态与最近一条状态消息；
- **通道模式**：在「设置…」里填好服务器/通道名/accesskey（先点「测试连接」验通再保存），
  宠物即按所选间隔（5/10/15/30 秒）轮询：通道里的 state 决定宠物状态、
  event=milestone 触发庆祝、message 以气泡冒出（6 秒自动消失、点击立即消失）；
  通道数据超过 5 分钟没更新时宠物变暗（alpha 0.55），数据恢复后自动还原；
  网络出错自动指数退避重试（上限 120 秒），菜单里能看到当前通道状态；
- **设置说明**：设置窗口底部有逐项说明，包括默认服务器是谁的、自建服务器
  （用仓库内 `skill/relay-channel` 部署 skill）的方法、钥的存放规矩；
- **触摸穿透**开启后宠物点不动、拖不动（鼠标事件全穿过），用菜单栏菜单关掉它；
- **本地事件点缀**：系统/屏幕唤醒、解锁屏幕会插播一遍「刚醒来」（正在办公/做东西时不打断）；
  睡眠/锁屏时自动暂停播放。

## 验收点

- [ ] 透明是否生效：宠物周围无白色方块，深色壁纸与浅色壁纸下各看一次
- [ ] 角色边缘毛发是否完整、高光处有没有被啃成半透明
- [ ] 视频方向是否正立（若上下颠倒，把 `PetVideoRenderer.swift` 里顶点着色器的 uvs 顺序上下翻转一行即可）
- [ ] 办公状态底部白色桌面带在深色壁纸上是否留浅色边（已知项，与 Android 版一致，先记录观感）
- [ ] 拖动跟手、松手后位置是否记住；切换桌面空间/全屏应用时宠物是否还在
- [ ] 菜单切状态：循环态是否无缝循环，苏醒/里程碑是否播一遍回落到之前状态；连点是否被 2 秒防抖拦住（日志有记录）
- [ ] 合盖睡醒/解锁后是否插播「刚醒来」；触摸穿透开/关是否符合预期
- [ ] 出问题看日志：`~/Library/Logs/HatchPet.log`（状态切换、被拒原因、Metal 初始化都在里面）

## 已知限制

- **真机未验**：本工程在 Linux 上只做了静态自检，编译与运行效果以 GitHub Actions
  首次构建和 Mac 实测为准；
- **Metal 回退路径**：若设备 Metal 初始化或着色器编译失败，自动回退 AVPlayerLayer
  普通播放（带白底、保功能），日志里会写明失败原因；
- **循环方式**：用「播完 seek 回 0」代替 AVPlayerLooper（looper 复制 item 后
  AVPlayerItemVideoOutput 挂载不可靠），循环接缝处可能有极短停顿，实测后评估；
- **真机未验**：设置窗口、气泡、变暗效果与 v0.6 的钥文件读写均待 Mac 实测；
- 未做：开机自启；通道长轮询（协议已留 since/seq，后续可加）。

## v0.2 新增验收点

- [ ] 设置窗口：填默认服务器 + hatch-pet 通道 + 钥，测试连接显示 seq/状态/数据时间；保存后菜单通道状态变「已连接」
- [ ] 用 relay.mjs 往通道写 working + message，宠物应在轮询间隔内切到办公并冒泡显示消息，菜单出现「最新消息」
- [ ] 写 event=milestone，宠物播一遍庆祝回落；断网/停写 5 分钟后宠物变暗，恢复写入后还原
- [ ] 尺寸菜单出现 100pt 并可切换；清空钥保存后通道关闭、宠物回本地手动模式

## v0.3 新增

- 设置面板新增「导出 skill」小节：钥匙串里有当前通道的 accesskey 时可点
  「导出 skill 包…」，运行时把内置 skill 模板（打包在 .app 的
  `Contents/Resources/skill/relay-channel`，源自仓内 `skill/`）现组包，
  并生成含当前服务器/通道名/accesskey 的 `pet-channel.json` 写进包根，
  打成 `relay-channel-setup-skill.zip` 让用户选位置保存。拿到包的人装上
  skill 并按其中 pet-channel.json 的说明即可读写这条通道——包内含钥，
  只发给信任的人。无钥时按钮禁用并注明先填钥保存。
- 随仓 skill 的 SKILL.md 同步新增「随包配置 pet-channel.json」一节（导出模板
  即仓内 skill/，天然一致）。

## v0.3 新增验收点

- [ ] 设置里填好钥并保存后，「导出 skill 包…」按钮变可点；未填钥时禁用且有小字说明
- [ ] 导出后解压 zip：relay-channel-setup/ 下有 SKILL.md、assets/ 四件与 pet-channel.json（内容为当前服务器/通道/钥）
- [ ] 换一台 Mac 或另一个 Muse 装这个包，能按 SKILL.md 说明读到该通道状态

## v0.6 新增

- **accesskey 改存本机文件，彻底不用系统钥匙串**：钥匙串在 ad-hoc 签名应用上
  会弹权限提示，自用场景没必要。改为 `KeyFileStore`：钥存
  `~/Library/Application Support/HatchPet/keys/<通道名>.key`（目录 700、文件 600，
  读时 trim），代码里零 Security 框架调用。**不做旧钥迁移**：v0.5 及以前存进
  钥匙串的钥在 v0.6 视为未保存，升级后在设置里重填一次即可；设置说明与
  「导出 skill」按钮的可用性判定都改查钥文件。
- **随仓 skill 补「宠物状态协议」章节**：`skill/relay-channel/SKILL.md` 新增
  一节，定版 HatchPet 的状态写入协议——state 词表（idle/working/making，
  sleeping 不写）、一次性 event（waking/milestone）、message 冒泡规矩、
  写时机 hook 对照表、节流与心跳。装上 skill 的 Muse 照此节即可正确驱动宠物。

## v0.6 新增验收点

- [ ] 升级后设置里钥显示「尚未保存」，重填并保存后轮询恢复、导出按钮变可点，全程无钥匙串权限弹窗
- [ ] `~/Library/Application Support/HatchPet/keys/hatch-pet.key` 存在，目录权限 700、文件 600
- [ ] 按 SKILL.md「宠物状态协议」用 relay.mjs 写 milestone + message，宠物播庆祝并冒泡摘要

## v0.9 新增

- **消息气泡改说话泡泡形态**：原先是 layer 画的圆角矩形（真机反馈不够拟物）。
  改为 `BubbleView.draw` 用一条 NSBezierPath 一次画出完整轮廓：圆角 12 的主体 +
  底部中央向下的小尾巴（宽 14、高 8，直边），填充沿用 controlBackgroundColor、
  描边 separatorColor 0.5pt、面板柔和阴影保留。面板总高 = 主体高 + 尾巴高，
  文字区只在主体内（底部内边距不含尾巴）；文字规则（最大宽 240、最多 3 行、
  时长 6/8/10 秒、点击消失）全不变。尾巴尖对准宠物顶部中心（面板底边离宠物
  头顶 4pt）。出现时加 0.15 秒 alpha 淡入；原计划的 0.96→1 缩放未做（内容视图
  layer 由窗口托管、改 anchorPoint 会偏移渲染位置且无 Mac 可验，只交形态）。
  气泡日志加 `shape=speech` 标记。

## v0.9 新增验收点

- [ ] 写一条带 message 的状态，气泡为带下尾巴的说话泡泡、尾巴尖指向宠物头顶，文字不压尾巴
- [ ] 短消息仍是小气泡、约 40 字长消息折 2–3 行，时长分别约 6/8/10 秒
- [ ] 气泡淡入出现无闪烁；点一下立即消失；拖动宠物后气泡跟随且形态不变

## v0.10 新增

- **消息气泡改思想云形态**（用户在 A 现款说话泡泡 / B 异形软泡 / C 思想云三方案
  示意图里选了 C）：云团主体 + 两个递减圆点引向宠物头顶，思想泡经典样式
  （圆点与云团不相连、留小间隙）。绘制方案：AppKit 路径没有并集运算——
  `BubbleView.draw` 把核心椭圆与 12 个固定图案凸起圆（角度/半径数组写死、
  半径按云大小等比缩放）作为同向子路径叠进一条 NSBezierPath，非零缠绕
  填充即并集；描边不直接 stroke（会画出内部圆弧），改为先画同形外扩
  1.5pt 的 separatorColor 垫底、再画本体填充，垫底露出的圈即描边；
  圆点（半径 5 → 3.5）同法处理。阴影仍靠面板 hasShadow 按内容 alpha 重算。
- **文字安全区收紧**：云团内圈不规则，内容最大宽从 220 收到 200，
  核心椭圆半轴 = 文字半宽 + 30 / 半高 + 24，保证文字四角不压凸起凹口；
  最多 3 行、时长 6/8/10 秒、点击消失、0.15 秒淡入全不变。
- **朝向镜像已处理**：面板被迫贴宠物下方（上方放不下）时，布局整体镜像——
  圆点串在上、云团在下，思想泡的上下关系仍成立（v0.9 说话泡泡的尾巴此回退
  下不翻转，云版顺带解决）。气泡日志标记改 `shape=cloud`。

## v0.10 新增验收点

- [ ] 写一条带 message 的状态，气泡为云团 + 两圆点引线的思想云，轮廓干净无内部弧线、描边均匀
- [ ] 短消息仍是小云团、约 40 字长消息折 2–3 行且文字不压云边，时长分别约 6/8/10 秒
- [ ] 把宠物拖到屏幕顶部附近触发下方回退，气泡在宠物下方且圆点在上、云在下
- [ ] 气泡淡入出现无闪烁；点一下立即消失；拖动宠物后气泡跟随且形态不变

## v0.11 新增

- **思想云修匀**（针对真机截图反馈：凸起大小不均、左下有个凸起下垂像要滴
  下来、凹口描边不匀）：凸起图案重排——角度改为每 30° 一个（底部三个正对
  下方），半径改用相对基准 24pt 的系数（0.95–1.13，旧版是 19–27 的绝对值
  大落差）；底部一排（240°/270°/300°）做**下沿对齐**：圆心 y 按
  「圆心 − 半径 = 同一底线」反推，三者底边齐平、谁也不单独下垂（对齐量
  ≤ ±3pt，凸起与核心椭圆仍大幅重叠）；描边垫底外扩由 1.5pt 降到 1.0pt，
  凹口显粗随之减轻（等距偏移在凹口略粗是垫底法的固有近似）。其余不变：
  安全区 200 宽、圆点引线、镜像回退、shape=cloud 日志、6/8/10 秒。
- **按状态自定义形象**（设置新增「形象」小节）：五个状态各一行，显示来源
  （内置 / 自定义源文件名），可「选择文件…」（mp4/mov）或「恢复默认」。
  文件拷贝到 `~/Library/Application Support/HatchPet/assets/<state>.<ext>`
  （先拷临时文件再替换，失败回滚、不动旧设置；同状态换扩展名会清掉旧副本），
  映射与源文件名记 UserDefaults；播放器解析顺序改为自定义 → Bundle.main →
  Bundle.module，正播该状态时立即重载。自定义素材走同一条 Metal 抠像管线，
  帮助文字写明建议正方形、白底、480×480。动机：内置 idle 素材本身是大头
  特写（源视频构图如此、非裁切），想换全身待机的人可自备素材替换。
- **GitHub 自助更新**（设置新增「关于 / 更新」小节 + 启动静默检查）：
  更新源固定为公开仓 `zeronetizen/hatch-pet-mac` 的 Releases；检查与下载
  都走设置里的代理（RelaySession）。**发版规范随本版变更**：workflow 正式
  Release 的 tag 改为 `v<CFBundleShortVersionString>`（从 Packaging/Info.plist
  读，如 v0.11）、标题 `HatchPet v0.11`（旧 build-N 规范只留给历史版本）；
  检查逻辑跳过 draft/prerelease 与解析不出语义版本的条目（debug-*、
  build-*），在可解析条目里取最高版本与当前比较；解析不出时只提示手动
  看 Release 页、不乱报。启动自动检查每天最多一次（UserDefaults 记时间
  戳），失败静默记日志。确认更新后：下载 zip → ditto 解压 → 校验包内
  HatchPet.app 存在且其 Info.plist 版本确实更高 → 生成一次性助手脚本
  （临时目录）：等主进程退出 → 新包先 ditto 到目标旁暂存、成功后才换掉旧
  .app → 去 quarantine → open 新版 → 清理临时目录；助手日志单独写
  ~/Library/Logs/HatchPet-update-helper.log。任何一步失败都弹窗说明且旧版
  保持可用；不执行下载包里的任何脚本。

## v0.11 新增验收点

- [ ] 气泡云团凸起均匀、底部下沿齐平无单个下垂，描边粗细可接受
- [ ] 设置「形象」里给 idle 选一个自备 mp4，宠物待机立即换上新形象；恢复默认后切回大头特写
- [ ] 选一个损坏/非视频文件替换形象，应提示失败且原形象不变
- [ ] 设置「关于 / 更新」点检查更新：v0.11 刚发布时应显示已是最新；待有更高版本 Release 后应弹窗并能一键更新重启到新版
- [ ] 更新全程断网/关代理重试，应弹窗失败且旧版照常可用
