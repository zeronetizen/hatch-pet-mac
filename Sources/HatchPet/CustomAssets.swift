import Foundation

/// 按状态自定义形象（v0.11）：用户可在设置里为每个状态选一个自己的视频文件
/// （mp4/mov）替换内置动画。文件拷贝进本机应用数据目录
/// ~/Library/Application Support/MusePet/assets/<state>.<ext>，
/// 映射（state → 文件名）记 UserDefaults（键 assets.customFileNames）。
/// 播放器解析顺序：自定义文件存在 → 用它，否则内置 mp4（见 ResourceLocator）。
/// 自定义素材与内置素材走同一条 Metal 亮度抠像管线，白底素材效果最好。
/// 所有替换/恢复都记日志（状态 + 文件名，非敏感）。
enum CustomAssets {
    /// 自定义素材目录：~/Library/Application Support/MusePet/assets
    /// （v0.25 起目录名由 HatchPet 改为 MusePet；测试阶段不迁移旧目录。）
    static var assetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MusePet/assets", isDirectory: true)
    }

    private static let defaultsKey = "assets.customFileNames"
    private static let sourceNamesKey = "assets.customSourceNames"

    /// 全部自定义映射：state 原始值 → 落盘文件名（统一为 "<state>.<ext>"，如 "making.mov"）
    private static func mapping() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// 用户当时选中的源文件名（仅用于设置页展示来源；落盘名是归一化后的 <state>.<ext>）
    static func customSourceName(for state: PetState) -> String? {
        (UserDefaults.standard.dictionary(forKey: sourceNamesKey) as? [String: String])?[state.rawValue]
    }

    /// 某状态的自定义文件名（仅映射层面，不查文件是否存在）
    static func customFileName(for state: PetState) -> String? {
        mapping()[state.rawValue]
    }

    /// 某状态的自定义文件 URL：映射存在且文件在磁盘上才返回（ResourceLocator 用）。
    static func customURL(for state: PetState) -> URL? {
        guard let name = customFileName(for: state) else { return nil }
        let url = assetsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            PetLog.d("自定义形象 state=\(state.rawValue) 映射指向 \(name) 但文件不存在，视为未自定义")
            return nil
        }
        return url
    }

    /// 把用户选中的视频设为某状态的形象：拷贝到 assets 目录（<state>.<ext>），
    /// 清掉同状态异扩展名的旧副本，成功后才落映射。
    /// 失败（拷贝出错/源文件不可读）返回错误描述且不改动任何现有状态（回滚语义：
    /// 拷贝用临时文件 + 替换完成，失败时旧自定义与映射原样保留）。
    static func setCustom(state: PetState, sourceURL: URL) -> String? {
        let fm = FileManager.default
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "mp4" || ext == "mov" else {
            PetLog.d("自定义形象拒绝 state=\(state.rawValue) 源文件扩展名 .\(ext) 不在 mp4/mov 内")
            return "只支持 mp4 / mov 视频文件。"
        }
        do {
            try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        } catch {
            PetLog.d("自定义形象目录创建失败 state=\(state.rawValue)：\(error.localizedDescription)")
            return "应用数据目录创建失败：\(error.localizedDescription)"
        }
        let destName = "\(state.rawValue).\(ext)"
        let dest = assetsDirectory.appendingPathComponent(destName)
        let tmp = assetsDirectory.appendingPathComponent(".\(state.rawValue).tmp-\(UUID().uuidString).\(ext)")
        do {
            // 先拷到临时文件，确认源可读且拷贝完整后再替换正式文件——中途失败不破坏旧设置
            if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
            try fm.copyItem(at: sourceURL, to: tmp)
            let attrs = try fm.attributesOfItem(atPath: tmp.path)
            guard let size = attrs[.size] as? NSNumber, size.intValue > 0 else {
                try? fm.removeItem(at: tmp)
                PetLog.d("自定义形象拷贝结果为空文件 state=\(state.rawValue) 源=\(sourceURL.lastPathComponent)")
                return "拷贝到的文件为空，已取消替换。"
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            PetLog.d("自定义形象拷贝失败 state=\(state.rawValue) 源=\(sourceURL.lastPathComponent)：\(error.localizedDescription)（旧设置保持不变）")
            return "拷贝失败：\(error.localizedDescription)"
        }
        // 清掉同状态异扩展名的旧副本（如原先是 .mov、这次换成 .mp4）
        for other in ["mp4", "mov"] where other != ext {
            let stale = assetsDirectory.appendingPathComponent("\(state.rawValue).\(other)")
            if fm.fileExists(atPath: stale.path) {
                try? fm.removeItem(at: stale)
                PetLog.d("自定义形象清理旧副本 state=\(state.rawValue) file=\(stale.lastPathComponent)")
            }
        }
        var map = mapping()
        map[state.rawValue] = destName
        UserDefaults.standard.set(map, forKey: defaultsKey)
        var sources = (UserDefaults.standard.dictionary(forKey: sourceNamesKey) as? [String: String]) ?? [:]
        sources[state.rawValue] = sourceURL.lastPathComponent
        UserDefaults.standard.set(sources, forKey: sourceNamesKey)
        PetLog.d("自定义形象已设置 state=\(state.rawValue)（\(state.label)）源=\(sourceURL.lastPathComponent) 存为=\(destName)")
        return nil
    }

    /// 恢复某状态的内置形象：删掉自定义文件并摘除映射。返回是否原本有自定义。
    @discardableResult
    static func clearCustom(state: PetState) -> Bool {
        let fm = FileManager.default
        let had = customFileName(for: state) != nil
        for ext in ["mp4", "mov"] {
            let f = assetsDirectory.appendingPathComponent("\(state.rawValue).\(ext)")
            if fm.fileExists(atPath: f.path) {
                do {
                    try fm.removeItem(at: f)
                    PetLog.d("自定义形象文件已删除 state=\(state.rawValue) file=\(f.lastPathComponent)")
                } catch {
                    PetLog.d("自定义形象文件删除失败 state=\(state.rawValue) file=\(f.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
        if had {
            var map = mapping()
            map.removeValue(forKey: state.rawValue)
            UserDefaults.standard.set(map, forKey: defaultsKey)
            var sources = (UserDefaults.standard.dictionary(forKey: sourceNamesKey) as? [String: String]) ?? [:]
            sources.removeValue(forKey: state.rawValue)
            UserDefaults.standard.set(sources, forKey: sourceNamesKey)
        }
        PetLog.d("自定义形象已恢复默认 state=\(state.rawValue)（\(state.label)）原本有自定义=\(had)")
        return had
    }
}
