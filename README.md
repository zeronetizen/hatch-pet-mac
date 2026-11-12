# Hatch 悬浮宠物 · Mac 版（第一步：不联网原型）

把 Muse 的 5 个日常状态动画做成 macOS 桌面悬浮宠物：无边框透明窗口、始终置顶、
跨所有桌面空间，播放时用 GPU 着色器实时把视频白底抠成透明（与 Android v0.2 同方案同参数）。
本步为**不联网原型**：无任何网络代码，状态靠菜单手动切换 + 本地系统事件（睡醒/解锁）点缀。

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
│   ├── StatusMenuController.swift 菜单栏图标与菜单
│   ├── PetLog.swift               全量日志（~/Library/Logs/HatchPet.log + NSLog）
│   └── Resources/                 5 个原始 mp4（480×480 H.264，未重编码）
├── Packaging/Info.plist           LSUIElement、com.nonzero.hatchpet.mac、最低系统 13.0
├── assemble_app.sh                swift build universal → 组装 .app → ad-hoc 签名 → zip
└── .github/workflows/build.yml    push main / 手动触发 → macos-latest 构建 → artifact
```

## 构建方式

本机（Linux）编不了 macOS 应用，走 GitHub Actions 云端 Mac：

1. 把本目录内容推到公开仓的 `main` 分支（自动触发），或在仓库 Actions 页手动 **Run workflow**；
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
  尺寸（120/160/200/240pt）、触摸穿透、隐藏/显示、退出；
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
- 未做：联网轮询与 Muse 真实状态接入（第二步，与 Android 共用同一中转）、开机自启、图标文件。
