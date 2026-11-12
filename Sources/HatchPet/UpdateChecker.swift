import AppKit
import Foundation

/// GitHub 自助更新（v0.11）：从公开仓 zeronetizen/hatch-pet-mac 的 Releases
/// 检查新版并自助替换。发版规范（自 v0.11 起，见 .github/workflows/build.yml）：
/// 正式 Release 的 tag 为 v<语义版本>（如 v0.11）、标题含版本号、资产固定为
/// HatchPet-mac.zip；debug-* 是构建日志 Release，解析时一律跳过。
/// 检查与下载都走用户已配的代理（RelaySession，与轮询/测试连接同路），
/// 因为 GitHub 在用户网络环境下直连同样可能被干扰。
/// 安全边界：只认官方仓这一个源；下载后先校验解压结构与新版 Info.plist
/// 版本确实更高才替换；不执行下载包里的任何代码——替换动作用本 App 自己
/// 生成的一次性 shell 助手完成（等主进程退出 → 换 .app → 去隔离 → 重开）。
enum UpdateChecker {
    struct ReleaseInfo {
        var version: String      // 语义版本（不带 v 前缀），如 "0.11"
        var versionParts: [Int]
        var tag: String
        var title: String
        var notes: String
        var zipURL: URL
        var publishedAt: String
    }

    enum Outcome {
        case updateAvailable(ReleaseInfo)
        case upToDate(latest: String?)
        case unparsableLatest
        case failed(String)
    }

    private static let releasesAPI = "https://api.github.com/repos/zeronetizen/hatch-pet-mac/releases?per_page=30"
    private static let releasesPage = "https://github.com/zeronetizen/hatch-pet-mac/releases"
    private static let assetName = "HatchPet-mac.zip"
    private static let lastAutoCheckKey = "update.lastAutoCheckAt"

    // MARK: - 版本工具

    /// "0.11" / "v0.11" → [0, 11, 0]；含非数字段返回 nil。
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            let ps = String(p)
            guard let n = Int(ps), n >= 0, String(n) == ps else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        return out
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - 检查入口

    /// 启动时静默检查：每天最多一次（UserDefaults 记上次检查时间戳），
    /// 失败只记日志；发现新版才弹窗（与手动检查同一条提示路径）。
    static func checkOnLaunchIfNeeded() {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastAutoCheckKey)
        guard now - last >= 24 * 3600 else {
            PetLog.d("更新自动检查跳过：距上次检查 \(Int((now - last) / 3600))h（每天最多一次）")
            return
        }
        UserDefaults.standard.set(now, forKey: lastAutoCheckKey)
        PetLog.d("更新自动检查开始（启动静默检查）current=v\(currentVersionString)")
        performCheck(manual: false) { text in
            PetLog.d("更新自动检查结果：\(text)")
        }
    }

    /// 手动检查（设置页按钮）：结果经 status 回调显示在设置页状态行；
    /// 发现新版会 additionally 弹更新提示窗。
    static func checkManually(status: @escaping (String) -> Void) {
        PetLog.d("更新手动检查开始 current=v\(currentVersionString)")
        performCheck(manual: true, status: status)
    }

    private static func performCheck(manual: Bool, status: @escaping (String) -> Void) {
        guard let url = URL(string: releasesAPI) else {
            status("检查失败：API 地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("HatchPet/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let proxy = ChannelSettings.load().proxy
        let session = RelaySession.makeSession(proxy: proxy)
        PetLog.d("更新检查 GET api.github.com/repos/zeronetizen/hatch-pet-mac/releases proxy=\(proxy.summary)")
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            let outcome: Outcome
            if let error {
                outcome = .failed("网络错误：\(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failed("GitHub API 返回 HTTP \(http.statusCode)")
            } else if let data {
                outcome = interpret(data: data)
            } else {
                outcome = .failed("GitHub API 无响应数据")
            }
            DispatchQueue.main.async {
                switch outcome {
                case .updateAvailable(let info):
                    PetLog.d("发现新版 v\(info.version)（tag=\(info.tag) published=\(info.publishedAt)）current=v\(currentVersionString)")
                    status("发现新版本 v\(info.version)")
                    presentUpdatePrompt(info)
                case .upToDate(let latest):
                    PetLog.d("已是最新 current=v\(currentVersionString) latest=\(latest ?? "无")")
                    status("已是最新版本（当前 v\(currentVersionString)）")
                case .unparsableLatest:
                    PetLog.d("最新 Release 无法解析出语义版本（既有 build-* 旧规范或异常），不报有更新")
                    status("无法解析最新 Release 的版本号，请手动查看 Release 页：\(releasesPage)")
                case .failed(let msg):
                    PetLog.d("更新检查失败：\(msg)（manual=\(manual)）")
                    if manual { status("检查更新失败：\(msg)") }
                }
            }
        }.resume()
    }

    /// 解析 Releases 列表：跳过 draft/prerelease 与 tag 不是 v<语义版本> 的条目
    /// （debug-*、旧 build-*），在可解析条目里取版本最高且带 HatchPet-mac.zip 资产的一条。
    private static func interpret(data: Data) -> Outcome {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return .failed("GitHub API 响应不是预期的 JSON 列表")
        }
        var best: ReleaseInfo?
        var sawAnyRelease = false
        for item in list {
            if (item["draft"] as? Bool) == true || (item["prerelease"] as? Bool) == true { continue }
            sawAnyRelease = true
            guard let tag = item["tag_name"] as? String,
                  let parts = parseVersion(tag) else { continue }
            guard let assets = item["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
                  let dl = asset["browser_download_url"] as? String,
                  let zipURL = URL(string: dl) else {
                PetLog.d("更新解析：tag=\(tag) 版本可解析但缺 \(assetName) 资产，跳过")
                continue
            }
            let info = ReleaseInfo(
                version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                versionParts: parts,
                tag: tag,
                title: (item["name"] as? String) ?? tag,
                notes: (item["body"] as? String) ?? "",
                zipURL: zipURL,
                publishedAt: (item["published_at"] as? String) ?? "")
            if let cur = best {
                if isNewer(parts, than: cur.versionParts) { best = info }
            } else {
                best = info
            }
        }
        guard let best else {
            return sawAnyRelease ? .unparsableLatest : .failed("仓库没有任何 Release")
        }
        let current = parseVersion(currentVersionString) ?? [0, 0, 0]
        if isNewer(best.versionParts, than: current) {
            return .updateAvailable(best)
        }
        return .upToDate(latest: best.version)
    }

    // MARK: - 更新提示与安装

    private static func presentUpdatePrompt(_ info: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "发现 HatchPet 新版本 v\(info.version)"
        var notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty { notes = "（该版本未附说明，详情见仓库 README 的版本小节）" }
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        alert.informativeText = "当前版本 v\(currentVersionString)，新版本 v\(info.version)（\(info.publishedAt)）。\n\n\(notes)\n\n点「现在更新」将下载并自动替换当前应用后重启，设置与本机数据（钥文件、自定义形象）不受影响。"
        alert.addButton(withTitle: "现在更新")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            PetLog.d("用户确认更新到 v\(info.version)，开始下载")
            downloadAndInstall(info)
        } else {
            PetLog.d("用户推迟更新 v\(info.version)")
        }
    }

    /// 下载 → 解压 → 校验 → 生成助手脚本 → 退出主 App 由助手替换并重启。
    /// 任何一步失败都只弹窗说明 + 记日志，旧版原样可用（替换发生在主进程退出后）。
    private static func downloadAndInstall(_ info: ReleaseInfo) {
        let proxy = ChannelSettings.load().proxy
        let session = RelaySession.makeSession(proxy: proxy)
        var request = URLRequest(url: info.zipURL)
        request.timeoutInterval = 120
        request.setValue("HatchPet/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        PetLog.d("更新下载开始 url=\(info.zipURL.absoluteString) proxy=\(proxy.summary)")
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            if let error {
                fail("下载失败：\(error.localizedDescription)")
                return
            }
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200, let data, !data.isEmpty else {
                fail("下载失败：HTTP \(http)")
                return
            }
            PetLog.d("更新下载完成 bytes=\(data.count)，开始解压校验")
            DispatchQueue.main.async {
                installFromZip(data: data, info: info)
            }
        }.resume()
    }

    private static func installFromZip(data: Data, info: ReleaseInfo) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("hatchpet-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zipPath = work.appendingPathComponent(assetName)
            try data.write(to: zipPath)
            let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            guard runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path]) else {
                fail("解压下载包失败（ditto 退出码非 0）")
                return
            }
            let newApp = extractDir.appendingPathComponent("HatchPet.app")
            guard fm.fileExists(atPath: newApp.path) else {
                fail("下载包结构不对：解压后未找到 HatchPet.app")
                return
            }
            // 校验新包版本确实比当前新（读新包自己的 Info.plist，不信 tag）
            guard let bundle = Bundle(path: newApp.path),
                  let newVerStr = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let newParts = parseVersion(newVerStr) else {
                fail("无法读取新包的版本号，取消更新")
                return
            }
            let current = parseVersion(currentVersionString) ?? [0, 0, 0]
            guard isNewer(newParts, than: current) else {
                fail("新包版本 v\(newVerStr) 并不比当前 v\(currentVersionString) 新，取消更新")
                return
            }
            PetLog.d("更新校验通过：新包 v\(newVerStr) > 当前 v\(currentVersionString)，生成助手脚本并退出主 App")
            let target = Bundle.main.bundlePath
            let scriptPath = work.appendingPathComponent("update-helper.sh")
            let script = helperScript(workDir: work.path)
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath.path,
                              "\(ProcessInfo.processInfo.processIdentifier)",
                              newApp.path, target, work.path]
            try proc.run()
            PetLog.d("更新助手已启动 pid=\(proc.processIdentifier)，主 App 即将退出（target=\(target)）")
            // 给助手留出启动时间后退出主进程，助手会等本进程消失再替换
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            fail("准备更新失败：\(error.localizedDescription)")
        }
    }

    /// 一次性替换助手：等主进程退出 → ditto 覆盖当前 .app → 去隔离属性 → 重开新版。
    /// 日志写 ~/Library/Logs/HatchPet-update-helper.log（独立于主日志，便于事后核对）。
    private static func helperScript(workDir: String) -> String {
        """
        #!/bin/bash
        # HatchPet 自助更新助手（由 HatchPet v\(currentVersionString) 生成，勿手改）
        PID="$1"; NEW_APP="$2"; TARGET="$3"; WORK="$4"
        LOG="$HOME/Library/Logs/HatchPet-update-helper.log"
        exec >> "$LOG" 2>&1
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') helper start pid=$PID new=$NEW_APP target=$TARGET"
        for i in $(seq 1 100); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.3
        done
        if kill -0 "$PID" 2>/dev/null; then
          echo "主进程 30 秒未退出，放弃替换（旧版保持不变）"
          exit 1
        fi
        sleep 0.5
        STAGED="$(dirname "$TARGET")/.HatchPet-staged-$$"
        if ! ditto "$NEW_APP" "$STAGED"; then
          echo "ditto 暂存新包失败，旧版保持不变"
          rm -rf "$STAGED"
          exit 1
        fi
        rm -rf "$TARGET"
        if ! mv "$STAGED" "$TARGET"; then
          echo "新包就位失败——暂存副本在 $STAGED，请手动改名为 HatchPet.app"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        echo "替换完成，启动新版"
        open "$TARGET"
        rm -rf "$WORK"
        """
    }

    private static func runTool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch {
            PetLog.d("更新工具启动失败 \(path)：\(error.localizedDescription)")
            return false
        }
        p.waitUntilExit()
        PetLog.d("更新工具 \(path) 退出码 \(p.terminationStatus)")
        return p.terminationStatus == 0
    }

    private static func fail(_ message: String) {
        PetLog.d("更新失败：\(message)（旧版保持不变）")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "更新失败"
            alert.informativeText = "\(message)\n\n当前版本 v\(currentVersionString) 保持不变，可继续使用；也可以到 Release 页手动下载：\n\(releasesPage)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
