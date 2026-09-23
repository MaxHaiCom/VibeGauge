import Foundation

// 清理动作（破坏性）：杀孤儿进程、清 npx 缓存。改这里之前先读 killProcesses 的复核逻辑
extension ProcessScanner {
    // MARK: 清理动作

    public func stableOrphans(_ orphans: [OrphanProc], minSeconds: Double) -> [OrphanProc] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var next: [Int: (at: TimeInterval, cmd: String)] = [:]
        var out: [OrphanProc] = []
        for o in orphans {
            if let prev = orphanFirstSeen[o.pid], prev.cmd == o.cmd {
                next[o.pid] = prev
                if now - prev.at >= minSeconds { out.append(o) }
            } else {
                next[o.pid] = (now, o.cmd)      // 第一次见到，这轮不动它
            }
        }
        orphanFirstSeen = next
        return out
    }

    /// 按「快照里记下的命令行」逐个复核后再杀。
    /// 面板上的快照最多 8 秒前，而 macOS 的 pid 会回绕复用 —— 直接按旧 pid 开枪有可能打到刚起来的别的进程。
    /// 复核：pid 仍存在、ppid 仍为 1、命令行与快照一致；任一不符就跳过。
    /// 先 SIGTERM，300ms 后仍存活的补 SIGKILL。
    /// shouldProceed：发信号前最后确认一次（自动清理传「开关还开着吗」，手动清理不传）
    public func killProcesses(_ targets: [OrphanProc], shouldProceed: (() -> Bool)? = nil) -> (killed: Int, skipped: Int, freedMB: Double) {
        if targets.isEmpty { return (0, 0, 0) }
        lock.lock()
        let live = readProcs()
        lock.unlock()

        // 快照之后它可能开始监听端口了（有客户端要连）→ 这一轮放过。
        // lsof 本身失败（空输出）就分不清谁在监听 → 这一轮一个都不动，宁可少杀
        let lsofOut = execute("lsof -iTCP -sTCP:LISTEN -n -P")
        guard !lsofOut.isEmpty else {
            log.notice("kill skipped: lsof 无输出，无法复核监听端口")
            return (0, targets.count, 0)
        }
        if let shouldProceed, !shouldProceed() { return (0, targets.count, 0) }
        var listening = Set<Int>()
        for line in lsofOut.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace })
            if cols.count >= 2, let pid = Int(cols[1]) { listening.insert(pid) }
        }
        var confirmed: [OrphanProc] = []
        var skipped = 0
        for t in targets {
            guard let p = live[t.pid], p.ppid == 1, p.cmd == t.cmd, !listening.contains(t.pid) else {
                skipped += 1
                log.notice("kill skipped pid=\(t.pid) (已消失或 pid 被复用)")
                continue
            }
            confirmed.append(t)
        }
        if let shouldProceed, !shouldProceed() { return (0, targets.count, 0) }
        for t in confirmed { kill(pid_t(t.pid), SIGTERM) }
        usleep(300_000)
        lock.lock()
        let remaining = readProcs()
        lock.unlock()
        for t in confirmed where kill(pid_t(t.pid), 0) == 0 {
            // SIGTERM 后 pid 仍可能被复用，补刀也必须核对原快照。
            guard let p = remaining[t.pid], p.ppid == 1, p.cmd == t.cmd else {
                log.notice("SIGKILL skipped pid=\(t.pid) (已消失或 pid 被复用)")
                continue
            }
            kill(pid_t(t.pid), SIGKILL)
        }
        // 按实际结果报：发了信号不等于退出了（权限不够 / 进程卡在内核里都可能还活着）
        usleep(100_000)
        lock.lock()
        let after = readProcs()
        lock.unlock()
        let gone = confirmed.filter { t in after[t.pid].map { $0.cmd != t.cmd } ?? true }
        return (gone.count, skipped + confirmed.count - gone.count, gone.reduce(0.0) { $0 + $1.memMB })
    }

    public func cleanNPXCache() -> Double {
        lock.lock(); defer { lock.unlock() }
        let npxPath = "\(home)/.npm/_npx"
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: npxPath) else { return 0.0 }
        let npxURL = URL(fileURLWithPath: npxPath)
        let npmRoot = URL(fileURLWithPath: "\(home)/.npm").resolvingSymlinksInPath().standardizedFileURL
        let resolved = npxURL.resolvingSymlinksInPath().standardizedFileURL
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              resolved.path.hasPrefix(npmRoot.path + "/") else {
            log.error("拒绝清理 NPX 缓存：目录是符号链接或解析后越界")
            return 0.0
        }
        npxCache = nil
        let freedMB = npxCacheSizeMB()
        do {
            // 逐项删除不会沿子项的符号链接清理目标目录，也不需要把路径拼进 shell。
            for url in try fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: url)
            }
        } catch {
            log.error("NPX 缓存清理失败")
            npxCache = nil
            return max(0, freedMB - npxCacheSizeMB())
        }
        npxCache = nil
        return freedMB
    }
}
