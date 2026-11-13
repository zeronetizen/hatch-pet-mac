import AppKit
import Foundation

/// GitHub 自助更新（v0.11 上线，v0.13 换数据源）：从公开仓
/// zeronetizen/hatch-pet-mac 的 Releases 检查新版并自助替换。
/// 发版规范（自 v0.11 起，见 .github/workflows/build.yml）：正式 Release 的
/// tag 为 v<语义版本>（如 v0.13）、标题含版本号、资产固定为
/// HatchPet-mac.zip；debug-* 是构建日志 Release，解析时一律跳过。
/// 数据源（v0.13）：主用仓库网页端点 releases.atom，失败兜底 releases/latest
/// 的 302 跳转取 tag。GitHub 的 API 子域未认证限流 60 次/小时按出口 IP 算，
/// 用户经共享代理出口时额度常被他人用满（v0.11/v0.12 真机检查必报 403），
/// 代码里不要再用它。检查与下载都走用户已配的代理（RelaySession，与轮询/
/// 测试连接同路），因为 GitHub 在用户网络环境下直连同样可能被干扰。
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

    private static let repoBase = "https://github.com/zeronetizen/hatch-pet-mac"
    private static let releasesAtom = "https://github.com/zeronetizen/hatch-pet-mac/releases.atom"
    private static let releasesLatest = "https://github.com/zeronetizen/hatch-pet-mac/releases/latest"
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

    /// 检查流程（v0.13）：主数据源是仓库网页端点 releases.atom——GitHub 的
    /// API 子域未认证限流 60 次/小时按出口 IP 算，用户经共享代理出口时额度常被别人
    /// 用满、点检查必 403；atom 与 releases/latest 都是普通网页端点，不吃这
    /// 个限流。atom 请求失败、或解析不到任何带语义版本的条目时，再用
    /// releases/latest 的 302 跳转目标兜底取最新 tag（只有版本号、无说明）；
    /// 两路都失败才报检查失败，错误信息带实际端点与状态码便于再定位。
    private static func performCheck(manual: Bool, status: @escaping (String) -> Void) {
        let proxy = ChannelSettings.load().proxy
        fetchAtom(proxy: proxy) { entries, atomError in
            if let entries, let best = bestRelease(in: entries) {
                PetLog.d("更新检查（数据源=atom）：共 \(entries.count) 条，最高版本 v\(best.version)")
                finish(best: best, manual: manual, status: status)
                return
            }
            let atomWhy = atomError ?? "atom 里没有可解析出语义版本的条目"
            PetLog.d("更新检查：atom 未得到可用版本（\(atomWhy)），转 releases/latest 兜底")
            fetchLatestTag(proxy: proxy) { tag, latestError in
                if let tag, let parts = parseVersion(tag) {
                    let info = ReleaseInfo(
                        version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                        versionParts: parts,
                        tag: tag,
                        title: "MusePet \(tag)",
                        notes: "",
                        zipURL: downloadURL(forTag: tag),
                        publishedAt: "")
                    PetLog.d("更新检查（数据源=latest-redirect）：最新 tag=\(tag) v\(info.version)")
                    finish(best: info, manual: manual, status: status)
                } else if let tag {
                    PetLog.d("更新检查（数据源=latest-redirect）：tag=\(tag) 解析不出语义版本")
                    deliver(.unparsableLatest, manual: manual, status: status)
                } else {
                    let latestWhy = latestError ?? "无 Location 头"
                    deliver(.failed("releases.atom：\(atomWhy)；releases/latest：\(latestWhy)"),
                            manual: manual, status: status)
                }
            }
        }
    }

    /// 按 best 与当前版本比较得出 Outcome，走与原来相同的提示路径。
    private static func finish(best: ReleaseInfo, manual: Bool, status: @escaping (String) -> Void) {
        let current = parseVersion(currentVersionString) ?? [0, 0, 0]
        let outcome: Outcome = isNewer(best.versionParts, than: current)
            ? .updateAvailable(best) : .upToDate(latest: best.version)
        deliver(outcome, manual: manual, status: status)
    }

    private static func deliver(_ outcome: Outcome, manual: Bool, status: @escaping (String) -> Void) {
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
    }

    /// 拉 releases.atom 并解析成条目；失败时回 (nil, 带端点与状态码的原因）。
    private static func fetchAtom(proxy: ProxyConfig,
                                  completion: @escaping ([AtomEntry]?, String?) -> Void) {
        guard let url = URL(string: releasesAtom) else {
            completion(nil, "releases.atom 地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("HatchPet/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let session = RelaySession.makeSession(proxy: proxy)
        PetLog.d("更新检查 GET releases.atom proxy=\(proxy.summary)")
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            if let error {
                completion(nil, "releases.atom 网络错误：\(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let data else {
                completion(nil, "releases.atom 返回 HTTP \(code)")
                return
            }
            guard let entries = AtomFeedParser().parse(data) else {
                completion(nil, "releases.atom XML 解析失败")
                return
            }
            completion(entries, nil)
        }.resume()
    }

    /// 兜底：请求 releases/latest 但不跟随 302，从 Location 头取最新 tag。
    private static func fetchLatestTag(proxy: ProxyConfig,
                                       completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: releasesLatest) else {
            completion(nil, "releases/latest 地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("HatchPet/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let stopper = RedirectStopper()
        let session = URLSession(configuration: RelaySession.makeConfiguration(proxy: proxy),
                                 delegate: stopper, delegateQueue: nil)
        PetLog.d("更新检查 GET releases/latest（不跟随跳转）proxy=\(proxy.summary)")
        session.dataTask(with: request) { _, response, error in
            session.finishTasksAndInvalidate()
            if let error {
                completion(nil, "releases/latest 网络错误：\(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(nil, "releases/latest 无 HTTP 响应")
                return
            }
            if let loc = http.value(forHTTPHeaderField: "Location"),
               let tagURL = URL(string: loc), tagURL.path.contains("/releases/tag/") {
                completion(tagURL.lastPathComponent, nil)
            } else {
                completion(nil, "releases/latest 返回 HTTP \(http.statusCode) 且无可用 Location")
            }
        }.resume()
    }

    /// 在 atom 条目里取版本最高的一条：tag 解析不出语义版本的（debug-*、旧
    /// build-*）跳过；资产下载地址按既定模式拼，不依赖 feed 内容。
    private static func bestRelease(in entries: [AtomEntry]) -> ReleaseInfo? {
        var best: ReleaseInfo?
        for entry in entries {
            guard let parts = parseVersion(entry.tag) else { continue }
            let info = ReleaseInfo(
                version: entry.tag.hasPrefix("v") ? String(entry.tag.dropFirst()) : entry.tag,
                versionParts: parts,
                tag: entry.tag,
                title: entry.title.isEmpty ? "MusePet \(entry.tag)" : entry.title,
                notes: plainText(fromHTML: entry.contentHTML),
                zipURL: downloadURL(forTag: entry.tag),
                publishedAt: entry.updated)
            if let cur = best {
                if isNewer(parts, than: cur.versionParts) { best = info }
            } else {
                best = info
            }
        }
        return best
    }

    private static func downloadURL(forTag tag: String) -> URL {
        URL(string: "\(repoBase)/releases/download/\(tag)/\(assetName)")!
    }

    /// atom 的 content 是 HTML：块级标签转行、其余标签剥掉、常见实体还原、
    /// 空行压缩，最后截 600 字作更新弹窗的说明摘要。
    static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|li|h[1-6]|ol|ul|div|blockquote)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<li[^>]*>", with: "• ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // &amp; 放最后还原，避免把 &amp;lt; 二次解成 <
        for (entity, ch) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                             ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: ch)
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        s = lines.joined(separator: "\n")
        if s.count > 600 { s = String(s.prefix(600)) }
        return s
    }

    // MARK: - 更新提示与安装

    private static func presentUpdatePrompt(_ info: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "发现 MusePet 新版本 v\(info.version)"
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

/// releases.atom 的一个条目（只收检查更新需要的四样）。tag 从条目链接
/// .../releases/tag/<tag> 的末段取；contentHTML 是 content 里的原始 HTML
/// （XML 实体已被 XMLParser 解过一层），转纯文本在 UpdateChecker.plainText。
struct AtomEntry {
    var tag: String
    var title: String
    var updated: String
    var contentHTML: String
}

/// 极简 Atom 解析器：逐 entry 收 alternate 链接 href、title、updated、content。
private final class AtomFeedParser: NSObject, XMLParserDelegate {
    private var entries: [AtomEntry] = []
    private var inEntry = false
    private var link = ""
    private var title = ""
    private var updated = ""
    private var content = ""
    private var text = ""

    func parse(_ data: Data) -> [AtomEntry]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" {
            inEntry = true
            link = ""; title = ""; updated = ""; content = ""
        } else if inEntry, elementName == "link" {
            if (attributeDict["rel"] ?? "alternate") == "alternate" {
                link = attributeDict["href"] ?? ""
            }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { text = "" }
        guard inEntry else { return }
        switch elementName {
        case "title":
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "updated":
            if updated.isEmpty { updated = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "content":
            content = text
        case "entry":
            let tag = URL(string: link)?.lastPathComponent ?? ""
            entries.append(AtomEntry(tag: tag, title: title, updated: updated, contentHTML: content))
            inEntry = false
        default:
            break
        }
    }
}

/// 让 URLSession 在重定向处停下（返回 nil 表示不跟随），把 302 响应原样交回
/// dataTask 的 completion——UpdateChecker 靠它读 releases/latest 的 Location。
private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
