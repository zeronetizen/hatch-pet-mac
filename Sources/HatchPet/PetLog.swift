import Foundation

/// 全量调试日志：写 ~/Library/Logs/HatchPet.log（带时间戳、环形保留约 2000 行）+ NSLog。
/// 关键路径必须打日志：启动、资源定位结果、Metal 初始化/着色器编译、状态切换
/// （来源/目标/被拒原因）、一次性状态回落、窗口位置保存、睡醒/解锁事件、播放器错误。
enum PetLog {
    private static let queue = DispatchQueue(label: "com.nonzero.hatchpet.mac.log")
    private static let maxLines = 2000
    private static var lines: [String] = []
    private static var handle: FileHandle?

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("HatchPet.log")
    }()

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func setup() {
        var historyCount = 0
        queue.sync {
            let dir = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
                lines = existing
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                if lines.count > maxLines {
                    lines = Array(lines.suffix(maxLines))
                }
            }
            historyCount = lines.count
            handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
        }
        d("PetLog 就绪 path=\(logURL.path) 历史行数=\(historyCount)")
    }

    static func d(_ msg: String) {
        let line = "\(fmt.string(from: Date()))  \(msg)"
        NSLog("[HatchPet] %@", msg)
        queue.async {
            lines.append(line)
            if let data = (line + "\n").data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
            if lines.count > maxLines + 200 {
                lines = Array(lines.suffix(maxLines))
                rewriteLocked()
            }
        }
    }

    /// 在 queue 内调用：把内存中的环形缓冲整体回写文件，实现截断。
    private static func rewriteLocked() {
        let text = lines.joined(separator: "\n") + "\n"
        try? handle?.close()
        handle = nil
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
    }
}
