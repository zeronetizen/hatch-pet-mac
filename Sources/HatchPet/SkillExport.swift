import AppKit
import UniformTypeIdentifiers

/// skill 包导出共用件（v0.18）：把 .app 内置模板（Contents/Resources/skill/<包名>）
/// 拷到临时目录、按需写附加文件、弹保存框打 zip。引导页的两个导出（领取包 /
/// 自建包）共用；设置页原有的「导出当前通道」沿用其自身流程。
enum SkillExport {
    /// 模板目录（assemble 时拷入 Contents/Resources/skill/）；缺失返回 nil。
    static func templateDir(_ package: String) -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("skill/\(package)", isDirectory: true)
        let md = dir.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: md.path) ? dir : nil
    }

    /// 导出一个 skill 包。extraFiles：包根目录相对文件名 → 内容（如 pet-owner.json）。
    /// 返回给用户看的结果文案（成功含路径），全程记 dbg 日志。
    static func export(package: String, suggestedName: String,
                       extraFiles: [String: String] = [:]) -> String {
        guard let template = templateDir(package) else {
            PetLog.d("[skill-export] 失败 package=\(package)：Bundle 内无模板")
            return "导出失败：应用内未找到 \(package) 的 skill 模板。"
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("hatchpet-skill-export-\(UUID().uuidString)", isDirectory: true)
        let pkgDir = staging.appendingPathComponent(package, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: template.path) {
                try fm.copyItem(at: template.appendingPathComponent(item),
                                to: pkgDir.appendingPathComponent(item))
            }
            for (name, content) in extraFiles {
                try content.write(to: pkgDir.appendingPathComponent(name),
                                  atomically: true, encoding: .utf8)
                PetLog.d("[skill-export] 附加文件已写入 package=\(package) file=\(name)")
            }
            PetLog.d("[skill-export] 组包完成 package=\(package)")
        } catch {
            PetLog.d("[skill-export] 组包失败 package=\(package)：\(error.localizedDescription)")
            return "导出失败：组包出错（\(error.localizedDescription)）"
        }
        let panel = NSSavePanel()
        panel.title = "导出 skill 包"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else {
            PetLog.d("[skill-export] 用户取消 package=\(package)")
            return "已取消导出。"
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            let ok: Bool
            if fm.fileExists(atPath: "/usr/bin/ditto") {
                ok = runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", pkgDir.path, dest.path])
            } else {
                ok = runTool("/usr/bin/zip", ["-r", dest.path, package], currentDir: staging.path)
            }
            guard ok else {
                throw NSError(domain: "HatchPetSkillExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "打包命令执行失败"])
            }
        } catch {
            PetLog.d("[skill-export] 打包失败 package=\(package)：\(error.localizedDescription)")
            return "导出失败：\(error.localizedDescription)"
        }
        PetLog.d("[skill-export] 成功 package=\(package) 路径=\(dest.path)")
        return "已导出到：\(dest.path)——把整个包交给你的智能体即可。"
    }

    private static func runTool(_ path: String, _ args: [String], currentDir: String? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let currentDir { p.currentDirectoryURL = URL(fileURLWithPath: currentDir) }
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch {
            PetLog.d("[skill-export] 工具启动失败 \(path)：\(error.localizedDescription)")
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
