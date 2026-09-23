import Foundation

// 磁盘盘点：AI 工具目录占用、按保留期清理会话记录
extension ProcessScanner {
    // MARK: 磁盘占用与会话日志治理

    /// 保留天数（`defaults write com.haifeng.vibegauge logRetentionDays 60` 可改，下限 7 天）
    public var logRetentionDays: Int {
        let v = UserDefaults.standard.integer(forKey: "logRetentionDays")
        return v >= 7 ? v : 30
    }

    /// 保留期硬下限 7 天：本工具自己要读近两天的会话文件算额度，太短会把还在用的删掉
    public static func effectiveRetention(_ days: Int) -> Int { max(7, days) }

    /// 允许按年龄清理的目录：只有「会话记录」。删掉的后果写在 note 里，面板要原样显示给用户看。
    /// 绝不放进来的：sqlite 运行库（删了工具会坏）、plugins/skills（是安装的东西）、
    /// generated_images/downloads（是用户资产）。这些只统计、不提供按钮。
    var purgeableDirs: [(path: String, label: String, note: String)] {
        [("\(home)/.codex/sessions", L("Codex 会话记录", "Codex sessions"), L("删掉就不能 --resume 这些旧会话", "Deleting prevents --resume for these sessions")),
         ("\(home)/.grok/sessions", L("Grok 会话记录", "Grok sessions"), L("删掉就不能回看这些旧会话", "Deleting removes access to these past sessions")),
         ("\(home)/.claude/projects", L("Claude 会话记录", "Claude sessions"), L("删掉就不能 --resume / --continue 这些旧会话", "Deleting prevents --resume / --continue for these sessions"))]
    }

    /// 只统计不清理的大块（让用户自己判断，而不是我们替他删）
    var reportOnlyPaths: [(path: String, label: String, note: String)] {
        [("\(home)/.codex/logs_2.sqlite", L("Codex 日志库", "Codex log database"), L("运行时数据库，删了会弄坏 Codex", "Runtime database; deleting breaks Codex")),
         ("\(home)/.codex/thread_history_1.sqlite", L("Codex 会话库", "Codex session database"), L("运行时数据库，删了会弄坏 Codex", "Runtime database; deleting breaks Codex")),
         ("\(home)/.codex/generated_images", L("Codex 生成的图片", "Codex generated images"), L("你的产物，自己决定", "Your assets; decide yourself")),
         ("\(home)/.grok/downloads", L("Grok 下载", "Grok downloads"), L("你的产物，自己决定", "Your assets; decide yourself")),
         ("\(home)/.codex/plugins", L("Codex 插件", "Codex plugins"), L("装上的东西，不是缓存", "Installed content, not a cache")),
         ("\(home)/.claude/plugins", L("Claude 插件", "Claude plugins"), L("装上的东西，不是缓存", "Installed content, not a cache"))]
    }

    /// 遍历 + stat 实测 0.4s 左右（约 1 万个文件），10 分钟节流足够
    public func scanDisk() -> (items: [DiskItem], totalGB: Double) {
        let now = Date().timeIntervalSince1970
        if let c = diskCache, now - c.at < 600 { return (c.items, c.totalGB) }

        let cutoff = now - Double(logRetentionDays) * 86400
        var items: [DiskItem] = []

        for d in purgeableDirs {
            guard FileManager.default.fileExists(atPath: d.path) else { continue }
            var it = DiskItem(path: d.path, label: d.label, purgeable: true, note: d.note)
            // 一次遍历同时拿到大小与 mtime，按保留期分桶
            let out = execute("/usr/bin/find '\(d.path)' -type f -print0 2>/dev/null | /usr/bin/xargs -0 /usr/bin/stat -f '%z %m' 2>/dev/null")
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let size = Double(parts[0]), let mtime = Double(parts[1]) else { continue }
                it.files += 1
                it.totalMB += size / 1_048_576
                if mtime < cutoff {
                    it.oldFiles += 1
                    it.oldMB += size / 1_048_576
                }
            }
            items.append(it)
        }

        for r in reportOnlyPaths {
            guard FileManager.default.fileExists(atPath: r.path) else { continue }
            guard let kb = Double(execute("/usr/bin/du -sk '\(r.path)'").components(separatedBy: "\t").first?
                                    .trimmingCharacters(in: .whitespaces) ?? "") else { continue }
            let mb = kb / 1024
            if mb < 50 { continue }        // 小块不占版面
            items.append(DiskItem(path: r.path, label: r.label, totalMB: mb, purgeable: false, note: r.note))
        }

        var totalGB = 0.0
        for root in [".codex", ".grok", ".claude", ".gemini"] {
            if let kb = Double(execute("/usr/bin/du -sk '\(home)/\(root)'").components(separatedBy: "\t").first?
                                .trimmingCharacters(in: .whitespaces) ?? "") { totalGB += kb / 1_048_576 }
        }

        items.sort { $0.totalMB > $1.totalMB }
        diskCache = (now, items, totalGB)
        return (items, totalGB)
    }

    /// 清理超过保留期的会话记录。**放回收站而不是 rm** —— 误删了还能捞回来。
    /// 四道闸：目录必须在白名单里、必须是普通文件、mtime 必须早于截止点、保留期下限 7 天。
    public func purgeOldSessionLogs(olderThanDays: Int) -> (files: Int, freedMB: Double, failed: Int) {
        let days = Self.effectiveRetention(olderThanDays)
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        let fm = FileManager.default
        var files = 0, failed = 0
        var freed = 0.0

        for d in purgeableDirs {
            let root = URL(fileURLWithPath: d.path).resolvingSymlinksInPath().standardizedFileURL
            guard let e = fm.enumerator(at: URL(fileURLWithPath: d.path),
                                        includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                      v.isSymbolicLink == false,
                      url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"), // 闸 1：解析链接后仍在白名单目录
                      v.isRegularFile == true,                                  // 闸 2：只动普通文件
                      let mt = v.contentModificationDate, mt.timeIntervalSince1970 < cutoff  // 闸 3：确实够旧
                else { continue }
                let size = Double(v.fileSize ?? 0) / 1_048_576
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)            // 闸 4：进回收站，可恢复
                    files += 1
                    freed += size
                } catch {
                    failed += 1
                }
            }
        }
        diskCache = nil
        log.notice("清理会话记录：\(days) 天前，\(files) 个文件，\(Int(freed)) MB，失败 \(failed)")
        return (files, freed, failed)
    }

    func npxCacheSizeMB() -> Double {
        let now = Date().timeIntervalSince1970
        if let c = npxCache, now - c.at < 300 { return c.mb }
        let npxPath = "\(home)/.npm/_npx"
        var mb = 0.0
        if FileManager.default.fileExists(atPath: npxPath),
           let first = execute("/usr/bin/du -sk '\(npxPath)'").components(separatedBy: "\t").first,
           let kb = Double(first.trimmingCharacters(in: .whitespaces)) {
            mb = kb / 1024.0
        }
        npxCache = (mb, now)
        return mb
    }
}
