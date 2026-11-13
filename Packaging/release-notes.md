MusePet Mac 版 v0.25：内部全改名 MusePet（包名、bundle id、数据目录、安装包）、设置页说明文字清理。本版为测试阶段版本，老数据不迁移。

1. **全改名**：程序包由 `HatchPet.app` 改为 `MusePet.app`，可执行名 MusePet，bundle id 改为 `com.nonzero.musepet.mac`，安装包改名 `MusePet-mac.zip`；本机数据目录改到 `~/Library/Application Support/MusePet/`，日志改到 `~/Library/Logs/MusePet.log`。自本版起，App 内自助更新走新资产名 `MusePet-mac.zip`。
2. **老数据不迁移（测试阶段安排）**：新版首启即全新状态——旧版的通道配置、代理设置、本机钥文件都**不会**自动带过来。请装好后重走一次引导：粘贴通道码点「连接」即可恢复；钥文件如需保留，可手动把旧目录 `~/Library/Application Support/HatchPet/keys/` 拷到新目录同名位置。
3. **0.24 及更早版本无法自动升级到本版**：旧版更新检查认的是旧资产名 `HatchPet-mac.zip`，而本版起 Release 只发 `MusePet-mac.zip`，请手动下载安装一次；本版之后自更新恢复正常。
4. **设置页文案清理**：删掉代理节、形象节、更新节的成段说明文字和状态行的静态提示（设置只显示操作与反馈）；「官网/落地页」按钮改名「官网」；「通道码已复制」等过长反馈缩短为一句事实。设置项本身、布局和即时生效行为不变。
5. **明确不动**：通道码（`hatchpet1:`）与领取串（`hatchpet-code1:`）格式、公共中转与通道、GitHub 仓库名都不变；源码目录与 SwiftPM 目标名仍为 HatchPet（内部构建标识，不影响使用）。

验收提示：解压后应得到 `MusePet.app`（不是 HatchPet.app）；首启应进入引导页（全新状态），按引导粘贴通道码连接成功后宠物即恢复状态同步；设置页各节应无成段说明文字，关于节按钮为「官网」。
