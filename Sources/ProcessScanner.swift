import Foundation

public struct ServiceGroup: Identifiable {
    public var id: String { serviceName }
    public let serviceName: String
    public var processCount: Int
    public var totalMemMB: Double
    public var pids: [Int]
}

public struct ScanReport {
    // 内存与虚拟内存
    public var freePercentage: Int = 0
    public var totalMemoryGB: Double = 0.0
    public var usedMemoryGB: Double = 0.0
    public var swapUsedGB: Double = 0.0
    public var compressorGB: Double = 0.0
    
    // 硬件与发热负载
    public var thermalStateString: String = "正常"
    public var loadAvg1m: Double = 0.0
    public var loadAvg5m: Double = 0.0
    public var diskFreeGB: Double = 0.0
    public var diskTotalGB: Double = 0.0
    public var diskFreePct: Double = 0.0
    
    // Vibe Coding 专属环境状态
    public var activeClaudeCount: Int = 0
    public var activeAgyCount: Int = 0
    public var activeMCPProcessCount: Int = 0
    public var activeMCPTotalMemMB: Double = 0.0
    
    // 程序员开发缓存
    public var npxCacheMB: Double = 0.0
    
    // 断链孤儿垃圾
    public var orphanedGroups: [ServiceGroup] = []
    public var allOrphanPids: [Int] = []
    public var totalOrphanCount: Int = 0
    public var totalOrphanMemMB: Double = 0.0
}

public class ProcessScanner {
    public static let shared = ProcessScanner()
    
    private let whitelist = [
        "CleanMyMac",
        "figma-agent-bridge",
        "tailscale",
        "docker",
        "com.docker",
        "/System",
        "/usr/libexec",
        "/usr/sbin"
    ]
    
    private let serviceDefinitions: [(key: String, name: String)] = [
        ("apple-docs", "Apple Docs 接口服务"),
        ("chrome-devtools", "Chrome DevTools 自动化插件"),
        ("notebooklm", "NotebookLM 交互插件"),
        ("xcodebuildmcp", "Xcode 构建工具插件"),
        ("mcpvault", "Obsidian Vault 插件"),
        ("magicuidesign", "Magic UI 设计工具"),
        ("meigen", "Meigen 图像服务"),
        ("context7", "Context7 检索服务")
    ]
    
    private func execute(_ cmd: String) -> String {
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
    
    public func scan() -> ScanReport {
        var report = ScanReport()
        
        // 1. memory_pressure
        let mp = execute("memory_pressure")
        for line in mp.components(separatedBy: "\n") {
            if line.contains("System-wide memory free percentage:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    let s = parts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    report.freePercentage = Int(s) ?? 0
                }
            } else if line.contains("Pages used by compressor:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    let pages = Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0.0
                    report.compressorGB = (pages * 16384.0) / (1024.0 * 1024.0 * 1024.0)
                }
            }
        }
        
        // 2. Total Memory
        let memStr = execute("sysctl -n hw.memsize").trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Double(memStr) {
            report.totalMemoryGB = bytes / (1024.0 * 1024.0 * 1024.0)
            report.usedMemoryGB = report.totalMemoryGB * (1.0 - Double(report.freePercentage) / 100.0)
        }
        
        // 3. Swap usage
        let swapStr = execute("sysctl vm.swapusage")
        if let regex = try? NSRegularExpression(pattern: "used\\s*=\\s*([0-9\\.]+)M") {
            let ns = swapStr as NSString
            if let match = regex.firstMatch(in: swapStr, range: NSRange(location: 0, length: ns.length)) {
                let valStr = ns.substring(with: match.range(at: 1))
                let mb = Double(valStr) ?? 0.0
                report.swapUsedGB = mb / 1024.0
            }
        }
        
        // 4. 硬件发热状态与 CPU 负载
        let thermal = ProcessInfo.processInfo.thermalState
        switch thermal {
        case .nominal: report.thermalStateString = "正常"
        case .fair: report.thermalStateString = "微热"
        case .serious: report.thermalStateString = "较高 (可能降频)"
        case .critical: report.thermalStateString = "严重过热"
        @unknown default: report.thermalStateString = "正常"
        }
        
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        report.loadAvg1m = loadavg[0]
        report.loadAvg5m = loadavg[1]
        
        // 5. 磁盘剩余空间
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            report.diskFreeGB = Double(freeBytes) / (1024.0 * 1024.0 * 1024.0)
            report.diskTotalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
            if report.diskTotalGB > 0 {
                report.diskFreePct = (report.diskFreeGB / report.diskTotalGB) * 100.0
            }
        }
        
        // 6. NPX 工具缓存大小 (~/.npm/_npx)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let npxPath = "\(home)/.npm/_npx"
        if FileManager.default.fileExists(atPath: npxPath) {
            let duOut = execute("/usr/bin/du -sk '\(npxPath)'")
            if let first = duOut.components(separatedBy: "\t").first, let kb = Double(first.trimmingCharacters(in: .whitespaces)) {
                report.npxCacheMB = kb / 1024.0
            }
        }
        
        // 7. Listening ports via lsof
        let lsofOut = execute("lsof -iTCP -sTCP:LISTEN -n -P")
        var listeningPids = Set<Int>()
        for line in lsofOut.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if cols.count >= 2, let pid = Int(cols[1]) {
                listeningPids.insert(pid)
            }
        }
        
        // 8. PS table & AI sessions inspection
        let psOut = execute("ps -axo pid,ppid,rss,%mem,command")
        let psLines = psOut.components(separatedBy: "\n").dropFirst()
        
        struct RawProc {
            let pid: Int
            let ppid: Int
            let memMB: Double
            let cmd: String
        }
        
        var allProcs: [Int: RawProc] = [:]
        let allKeywords = serviceDefinitions.map { $0.key } + ["_npx", "mcp"]
        
        for line in psLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            if parts.count >= 5 {
                guard let pid = Int(parts[0]),
                      let ppid = Int(parts[1]),
                      let rssKB = Double(parts[2]) else { continue }
                let cmd = String(parts[4])
                let memMB = rssKB / 1024.0
                allProcs[pid] = RawProc(pid: pid, ppid: ppid, memMB: memMB, cmd: cmd)
                
                let lowerCmd = cmd.lowercased()
                
                // 统计正在活跃的 AI 会话
                if ppid != 1 {
                    if cmd.contains("claude --") || (cmd.contains("claude") && cmd.contains("--resume")) {
                        report.activeClaudeCount += 1
                    } else if cmd.contains("agy --") || cmd.hasSuffix("/agy") {
                        report.activeAgyCount += 1
                    } else {
                        // 统计活跃挂载的 MCP 进程
                        let isMCP = allKeywords.contains(where: { lowerCmd.contains($0) })
                        let isRunner = lowerCmd.contains("node") || lowerCmd.contains("npm") || lowerCmd.contains("python") || lowerCmd.contains("uv")
                        if isMCP && isRunner {
                            report.activeMCPProcessCount += 1
                            report.activeMCPTotalMemMB += memMB
                        }
                    }
                }
            }
        }
        
        // 9. 甄别断链孤儿进程: PPID == 1, not listening on port, matching MCP signatures
        var orphanRootPids = Set<Int>()
        for (pid, proc) in allProcs {
            if proc.ppid != 1 { continue }
            if listeningPids.contains(pid) { continue }
            
            let cmd = proc.cmd
            let lowerCmd = cmd.lowercased()
            
            if whitelist.contains(where: { cmd.contains($0) }) {
                continue
            }
            
            let isRunner = lowerCmd.contains("node") || lowerCmd.contains("npm") || lowerCmd.contains("python") || lowerCmd.contains("uv")
            let hasSignature = allKeywords.contains(where: { lowerCmd.contains($0) })
            
            if isRunner && hasSignature {
                orphanRootPids.insert(pid)
            }
        }
        
        // 递归追踪孤儿的子进程 (例如 npm exec 派生的 node)
        var allOrphanPids = Set(orphanRootPids)
        var stack = Array(orphanRootPids)
        while !stack.isEmpty {
            let curr = stack.removeLast()
            for (p, proc) in allProcs {
                if proc.ppid == curr && !allOrphanPids.contains(p) {
                    allOrphanPids.insert(p)
                    stack.append(p)
                }
            }
        }
        
        // 按可读服务名聚类
        var groupMap: [String: (count: Int, mem: Double, pids: [Int])] = [:]
        for pid in allOrphanPids {
            guard let proc = allProcs[pid] else { continue }
            let lowerCmd = proc.cmd.lowercased()
            
            var matchedName = "其他已退出 AI 进程"
            for def in serviceDefinitions {
                if lowerCmd.contains(def.key) {
                    matchedName = def.name
                    break
                }
            }
            
            var curr = groupMap[matchedName, default: (count: 0, mem: 0.0, pids: [])]
            curr.count += 1
            curr.mem += proc.memMB
            curr.pids.append(pid)
            groupMap[matchedName] = curr
        }
        
        var groups: [ServiceGroup] = []
        for (name, val) in groupMap {
            groups.append(ServiceGroup(
                serviceName: name,
                processCount: val.count,
                totalMemMB: val.mem,
                pids: val.pids
            ))
        }
        
        groups.sort { $0.totalMemMB > $1.totalMemMB }
        report.orphanedGroups = groups
        report.allOrphanPids = Array(allOrphanPids)
        report.totalOrphanCount = allOrphanPids.count
        report.totalOrphanMemMB = groups.reduce(0.0) { $0 + $1.totalMemMB }
        
        return report
    }
    
    public func killProcesses(pids: [Int]) -> (killedCount: Int, freedMB: Double) {
        if pids.isEmpty { return (0, 0.0) }
        
        let report = scan()
        var freedMB: Double = 0.0
        var killedCount = 0
        
        for pid in pids {
            kill(pid_t(pid), SIGTERM)
            killedCount += 1
        }
        
        usleep(300_000)
        
        for pid in pids {
            if kill(pid_t(pid), 0) == 0 {
                kill(pid_t(pid), SIGKILL)
            }
        }
        
        freedMB = report.totalOrphanMemMB
        return (killedCount, freedMB)
    }
    
    public func cleanNPXCache() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let npxPath = "\(home)/.npm/_npx"
        var freedMB: Double = 0.0
        if FileManager.default.fileExists(atPath: npxPath) {
            let duOut = execute("/usr/bin/du -sk '\(npxPath)'")
            if let first = duOut.components(separatedBy: "\t").first, let kb = Double(first.trimmingCharacters(in: .whitespaces)) {
                freedMB = kb / 1024.0
            }
            _ = execute("/bin/rm -rf '\(npxPath)'/*")
        }
        return freedMB
    }
}
