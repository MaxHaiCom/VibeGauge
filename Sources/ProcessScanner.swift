import Foundation

public struct ProcessDetailItem: Identifiable {
    public let id: Int
    public let pid: Int
    public let ppid: Int
    public let name: String
    public let memMB: Double
    public let cmd: String
}

public struct ServiceGroup: Identifiable {
    public var id: String { serviceName }
    public let serviceName: String
    public var processCount: Int
    public var totalMemMB: Double
    public var pids: [Int]
}

public struct ScanReport {
    public var freePercentage: Int = 0
    public var totalMemoryGB: Double = 0.0
    public var usedMemoryGB: Double = 0.0
    public var swapUsedGB: Double = 0.0
    public var compressorGB: Double = 0.0
    
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
        
        // 4. Listening ports via lsof
        let lsofOut = execute("lsof -iTCP -sTCP:LISTEN -n -P")
        var listeningPids = Set<Int>()
        for line in lsofOut.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if cols.count >= 2, let pid = Int(cols[1]) {
                listeningPids.insert(pid)
            }
        }
        
        // 5. PS table
        let psOut = execute("ps -axo pid,ppid,rss,%mem,command")
        let psLines = psOut.components(separatedBy: "\n").dropFirst()
        
        struct RawProc {
            let pid: Int
            let ppid: Int
            let memMB: Double
            let cmd: String
        }
        
        var allProcs: [Int: RawProc] = [:]
        
        for line in psLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            if parts.count >= 5 {
                guard let pid = Int(parts[0]),
                      let ppid = Int(parts[1]),
                      let rssKB = Double(parts[2]) else { continue }
                let cmd = String(parts[4])
                allProcs[pid] = RawProc(pid: pid, ppid: ppid, memMB: rssKB / 1024.0, cmd: cmd)
            }
        }
        
        // Find orphan roots: PPID == 1, not listening on port, matching MCP/tool signatures
        var orphanRootPids = Set<Int>()
        let allKeywords = serviceDefinitions.map { $0.key } + ["_npx", "mcp"]
        
        for (pid, proc) in allProcs {
            if proc.ppid != 1 { continue }
            if listeningPids.contains(pid) { continue }
            
            let cmd = proc.cmd
            let lowerCmd = cmd.lowercased()
            
            // Whitelist
            if whitelist.contains(where: { cmd.contains($0) }) {
                continue
            }
            
            let isRunner = lowerCmd.contains("node") || lowerCmd.contains("npm") || lowerCmd.contains("python") || lowerCmd.contains("uv")
            let hasSignature = allKeywords.contains(where: { lowerCmd.contains($0) })
            
            if isRunner && hasSignature {
                orphanRootPids.insert(pid)
            }
        }
        
        // Trace children
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
        
        // Group by readable service name
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
}
