import Foundation
import os

// MARK: - 扫描器

public final class ProcessScanner {
    public static let shared = ProcessScanner()

    let lock = NSRecursiveLock()
    let log = Logger(subsystem: "com.haifeng.vibegauge", category: "scan")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let env = ProcessInfo.processInfo.environment

    // 缓存：JSON 文件按 mtime 缓存（~/.claude.json 有 200KB+，每秒解析太浪费）
    var jsonCache: [String: (mtime: TimeInterval, json: [String: Any])] = [:]
    // 缓存：会话 jsonl 增量解析状态
    struct FileParseState {
        var mtime: TimeInterval = 0
        var size: UInt64 = 0
        var parsedOffset: UInt64 = 0
        var head = Data()          // 文件前 256 字节指纹，识别原地重写 / 替换
        var turns: [String: InteractionRecord] = [:]
        var anomalies: [String: (ts: TimeInterval, final: Bool, kind: RequestAnomalies.Kind)] = [:]   // uuid → 错误事件
        var compactions: [String: Compaction] = [:]     // uuid → 压缩事件（compact_boundary）
    }
    /// Codex 活跃会话的增量读取状态（上下文水位、压缩次数）
    var codexCtxStates: [String: CodexCtxState] = [:]
    /// 最近一次 scanTokens 算出的今日请求异常（详情页用）
    var claudeAnomalies = RequestAnomalies()
    var fileStates: [String: FileParseState] = [:]
    /// 会话文件 → 工作目录。文件里写的 cwd 是权威值；目录名那种把 / 换成 - 的编码解不回来
    /// （`vibe-gauge` 会被拆成 vibe/gauge），所以一律读文件。读到就缓存，不重复读盘。
    var fileCwdCache: [String: String] = [:]

    // 缓存：贵操作节流
    var npxCache: (mb: Double, at: TimeInterval)? = nil
    /// 本机模型服务的 HTTP 探测结果（URL → 时刻 + JSON；json 为 nil = 不可达）
    var localProbeCache: [String: (at: TimeInterval, json: Any?)] = [:]

    /// 由 launchd 托管的常驻服务：ppid 天然是 1，但它们是「该活着的」，绝不能当孤儿杀。
    /// 从 plist 的 Program / ProgramArguments 里取出非解释器的实参当特征（取解释器路径会保护掉所有 python/node，太宽）。
    var launchdCache: (at: TimeInterval, tokens: [(token: String, label: String)])? = nil
    let interpreters: Set<String> = ["python", "python3", "node", "bun", "deno", "ruby", "perl", "sh", "bash", "zsh", "env", "uvx", "npx", "uv", "npm", "pnpm", "yarn", "open", "osascript"]

    let whitelist = [
        "CleanMyMac", "figma-agent-bridge", "tailscale", "docker", "com.docker",
        "/System", "/usr/libexec", "/usr/sbin"
    ]

    let serviceDefinitions: [(key: String, name: String)] = [
        ("apple-docs", L("Apple Docs 接口服务", "Apple Docs service")),
        ("chrome-devtools", L("Chrome DevTools 自动化插件", "Chrome DevTools automation")),
        ("notebooklm", L("NotebookLM 交互插件", "NotebookLM integration")),
        ("xcodebuildmcp", L("Xcode 构建工具插件", "Xcode build tool")),
        ("mcpvault", L("Obsidian Vault 插件", "Obsidian Vault plugin")),
        ("magicuidesign", L("Magic UI 设计工具", "Magic UI design tool")),
        ("meigen", L("Meigen 图像服务", "Meigen image service")),
        ("context7", L("Context7 检索服务", "Context7 retrieval service"))
    ]

    // MARK: 基础工具

    func execute(_ cmd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// 按 mtime 缓存的 JSON 读取
    func readJSON(_ path: String) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else {
            jsonCache[path] = nil
            return nil
        }
        let mtime = mod.timeIntervalSince1970
        if let c = jsonCache[path], c.mtime == mtime { return c.json }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        jsonCache[path] = (mtime, json)
        return json
    }

    /// 读文件尾部 maxBytes（整行对齐由调用方处理）
    func readTail(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    func parseISO(_ s: String?) -> TimeInterval? { Fmt.parseISODate(s) }

    func clampPct(_ n: NSNumber?) -> Int? {
        guard let n = n, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Fmt.pct(n.doubleValue)
    }

    // MARK: 全量扫描（8s 定时器）

    public func scan(refreshRemote: Bool = true) -> ScanReport {
        if refreshRemote { refreshRemoteCodexIfDue() }  // 自测只扫描本机，不为验收触发远程 SSH
        lock.lock(); defer { lock.unlock() }
        var report = ScanReport()

        // 1. memory_pressure（页大小从它自己的输出里读：Apple Silicon 16KB、Intel 4KB，写死会差 4 倍）
        let pressureOut = execute("memory_pressure")
        let pageBytes = Self.memoryPressurePageSize(pressureOut) ?? Double(getpagesize())
        for line in pressureOut.components(separatedBy: "\n") {
            if line.contains("System-wide memory free percentage:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    report.freePercentage = Int(parts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                }
            } else if line.contains("Pages used by compressor:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    let pages = Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0.0
                    report.compressorGB = pages * pageBytes / (1024.0 * 1024.0 * 1024.0)
                }
            }
        }

        // 2. 总内存
        if let bytes = Double(execute("sysctl -n hw.memsize").trimmingCharacters(in: .whitespacesAndNewlines)) {
            report.totalMemoryGB = bytes / (1024.0 * 1024.0 * 1024.0)
            report.usedMemoryGB = report.totalMemoryGB * (1.0 - Double(report.freePercentage) / 100.0)
        }

        // 3. Swap
        let swapStr = execute("sysctl vm.swapusage")
        if let regex = try? NSRegularExpression(pattern: "used\\s*=\\s*([0-9\\.]+)M") {
            let ns = swapStr as NSString
            if let m = regex.firstMatch(in: swapStr, range: NSRange(location: 0, length: ns.length)) {
                report.swapUsedGB = (Double(ns.substring(with: m.range(at: 1))) ?? 0.0) / 1024.0
            }
        }

        // 4. 发热与负载
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: report.thermalStateString = L("正常", "Normal")
        case .fair: report.thermalStateString = L("微热", "Warm")
        case .serious: report.thermalStateString = L("较高 (可能降频)", "High (may throttle)")
        case .critical: report.thermalStateString = L("严重过热", "Critical heat")
        @unknown default: report.thermalStateString = L("正常", "Normal")
        }
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        report.loadAvg1m = loadavg[0]
        report.loadAvg5m = loadavg[1]

        // 5. 磁盘
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            report.diskFreeGB = Double(freeBytes) / (1024.0 * 1024.0 * 1024.0)
            report.diskTotalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
            if report.diskTotalGB > 0 { report.diskFreePct = report.diskFreeGB / report.diskTotalGB * 100.0 }
        }

        // 6. NPX 缓存（du 走盘慢，5 分钟节流）
        report.npxCacheMB = npxCacheSizeMB()
        let disk = scanDisk()
        report.disk = disk.items
        report.diskTotalAIGB = disk.totalGB

        // 7. 监听端口
        var listeningPids = Set<Int>()
        for line in execute("lsof -iTCP -sTCP:LISTEN -n -P").components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace })
            if cols.count >= 2, let pid = Int(cols[1]) { listeningPids.insert(pid) }
        }

        // 8. 进程表 + 会话计数 + 活跃 MCP
        let procs = readProcs()
        let counts = countSessions(procs)
        let serviceKeys = serviceDefinitions.map { $0.key }
        for p in procs.values where p.ppid != 1 {
            let lower = p.cmd.lowercased()
            if ProcessScanner.isClaudeCLISession(cmd: p.cmd) || ProcessScanner.isCodexCLISession(cmd: p.cmd)
                || ProcessScanner.isAgyCLISession(cmd: p.cmd) || ProcessScanner.isGrokCLISession(cmd: p.cmd) { continue }
            if Self.isMCPServerCommand(lower, serviceKeys: serviceKeys) {
                report.activeMCPProcessCount += 1
                report.activeMCPTotalMemMB += p.memMB
            }
        }

        // 9. 孤儿：ppid==1 + 无监听端口 + 非白名单 + 非 launchd 托管 + runner + MCP 签名
        //    放过的都记下原因，面板要能解释"为什么没动它"
        let launchdTokens = launchdProtectedTokens()
        var orphanRoots = Set<Int>()
        var protectedList: [ProtectedProc] = []
        for (pid, p) in procs where p.ppid == 1 {
            let lower = p.cmd.lowercased()
            guard Self.isMCPServerCommand(lower, serviceKeys: serviceKeys) else { continue }
            if listeningPids.contains(pid) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: L("在监听端口（可能还有客户端会连）", "Listening on a port (a client may connect)")))
                continue
            }
            if let hit = whitelist.first(where: { p.cmd.contains($0) }) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: L("白名单：\(hit)", "Allowlisted: \(hit)")))
                continue
            }
            if let hit = launchdTokens.first(where: { p.cmd.contains($0.token) }) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: L("launchd 托管：\(hit.label)", "launchd-managed: \(hit.label)")))
                continue
            }
            orphanRoots.insert(pid)
        }
        report.protected = protectedList.sorted { $0.memMB > $1.memMB }
        var allOrphans = orphanRoots
        var stack = Array(orphanRoots)
        while let curr = stack.popLast() {
            for (pid, p) in procs where p.ppid == curr && !allOrphans.contains(pid) {
                allOrphans.insert(pid)
                stack.append(pid)
            }
        }
        var groupMap: [String: (count: Int, mem: Double, pids: [Int])] = [:]
        for pid in allOrphans {
            guard let p = procs[pid] else { continue }
            let lower = p.cmd.lowercased()
            let name = serviceDefinitions.first(where: { lower.contains($0.key) })?.name ?? L("其他已退出 AI 进程", "Other exited AI process")
            var g = groupMap[name, default: (0, 0.0, [])]
            g.count += 1
            g.mem += p.memMB
            g.pids.append(pid)
            groupMap[name] = g
        }
        report.orphanedGroups = groupMap.map { ServiceGroup(serviceName: $0.key, processCount: $0.value.count, totalMemMB: $0.value.mem, pids: $0.value.pids) }
            .sorted { $0.totalMemMB > $1.totalMemMB }
        report.orphans = allOrphans.compactMap { pid -> OrphanProc? in
            guard let p = procs[pid] else { return nil }
            let lower = p.cmd.lowercased()
            let name = serviceDefinitions.first(where: { lower.contains($0.key) })?.name ?? L("其他已退出 AI 进程", "Other exited AI process")
            return OrphanProc(pid: pid, cmd: p.cmd, memMB: p.memMB, service: name)
        }.sorted { $0.memMB > $1.memMB }
        report.allOrphanPids = Array(allOrphans)
        report.totalOrphanCount = allOrphans.count
        report.totalOrphanMemMB = report.orphanedGroups.reduce(0.0) { $0 + $1.totalMemMB }

        // 10. Token 遥测 + 11. 各平台档位/额度 + 12. API Key 调用
        report.tokens = scanTokens()
        report.detectedLLMs = withQuotaSamples(detectAllLLMRuntimes(counts))
        report.api = scanAPI()
        report.cliUsage = scanCLIUsage(claude: report.tokens)
        report.sessions = scanSessions()
        report.pending = scanPending()
        return report
    }

    /// 轻量探查（1s ticker）：只跑 ps 与小文件读取
    public func scanActiveLLMs() -> [DetectedLLMRuntime] {
        lock.lock(); defer { lock.unlock() }
        return withQuotaSamples(detectAllLLMRuntimes(countSessions(readProcs())))
    }

    /// 统一在出口处记额度采样并回填"近期速度"——全扫描与面板每秒的轻量刷新都走这里
    func withQuotaSamples(_ llms: [DetectedLLMRuntime]) -> [DetectedLLMRuntime] {
        let now = Date().timeIntervalSince1970
        let out = llms.map { var l = $0; sampleLLMQuotas(&l, now: now); return l }
        saveSamplesIfDue(now)      // 整轮记完再落盘，别让同一轮后面的键等下一个周期
        return out
    }

    var diskCache: (at: TimeInterval, items: [DiskItem], totalGB: Double)? = nil
    var codexFileCache: [String: (mtime: TimeInterval, parsed: CodexParse)] = [:]
    let remoteLock = NSLock()
    var remoteCodex: (at: TimeInterval, ok: Bool, parsed: CodexParse) = (0, false, CodexParse())
    var codexCandidates: (at: TimeInterval, paths: [String]) = (0, [])
    var grokQuotaCache: (mtime: TimeInterval, size: UInt64, weekly: QuotaWindow?, tier: String)? = nil
    // 会话 cwd/启动时长要跑 lsof + ps，太贵，不能跟着每秒的 ticker 跑 → 10s 节流
    var sessionCache: [String: (at: TimeInterval, pids: [Int], infos: [SessionInfo])] = [:]
    var codexUsageCache: [String: (mtime: TimeInterval, day: TimeInterval, usage: CLIUsage)] = [:]
    var codexBaseline: [String: (day: TimeInterval, usage: CLIUsage)] = [:]
    var planCache: (mtime: TimeInterval, plans: [String: PlanLimit])? = nil
    var priceCache: (mtime: TimeInterval, table: PriceTable)? = nil
    var apiCalls: [APICall] = []
    var apiFile = FileParseState()          // 只用 mtime/size/parsedOffset/head
    var healthCache: (at: TimeInterval, running: Bool, calls: Int)? = nil
    /// 每个额度窗口按时间记若干 (时刻, 已用%)，用来算近期速度。
    /// 键里带重置点 → 窗口一换就是新键，天然不会把上个窗口的样本混进来。
    /// 落盘 `~/.config/vibegauge/quota-samples.json`，重启不丢；只留 6 小时，文件几十 KB。
    /// 另有 `final2|<额度>` 键长期保存上周期终值（每个额度一笔），给「按作息」预测当先验。
    /// （v1.1.0/1.1.1 用的 `final|` 没校验「最后观测离重置够近」，不再读，按普通过期样本清掉）
    var qsamples: [String: [(t: TimeInterval, pct: Int)]] = [:]
    var qsamplesLoaded = false
    var qsamplesSavedAt: TimeInterval = 0
    var coverageCache: (at: TimeInterval, cov: ProxyCoverage)? = nil
    // 连续两次扫描都在、且已孤儿 minSeconds 以上，才允许静默清理
    var orphanFirstSeen: [Int: (at: TimeInterval, cmd: String)] = [:]
}
