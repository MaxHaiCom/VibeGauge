import Foundation

public struct ProcessInfoItem: Identifiable {
    public let id: Int
    public let pid: Int
    public let ppid: Int
    public let name: String
    public let memMB: Double
    public let cmd: String
}

public struct DevServerItem: Identifiable {
    public let id: Int
    public let pid: Int
    public let name: String
    public let port: String
    public let memMB: Double
    public let cmd: String
}

public struct ScanReport {
    public var freePercentage: Int = 0
    public var totalMemoryGB: Double = 0.0
    public var swapUsedMB: Double = 0.0
    public var compressorMB: Double = 0.0
    
    public var orphanedMCPs: [ProcessInfoItem] = []
    public var devServers: [DevServerItem] = []
    
    public var totalOrphanMemMB: Double {
        orphanedMCPs.reduce(0) { $0 + $1.memMB }
    }
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
    
    private let mcpKeywords = [
        "mcp",
        "_npx",
        "apple-docs",
        "chrome-devtools",
        "xcodebuildmcp",
        "notebooklm",
        "mcpvault",
        "magicuidesign",
        "meigen",
        "context7"
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
                    report.compressorMB = (pages * 16384.0) / (1024.0 * 1024.0)
                }
            }
        }
        
        // 2. Total Memory
        let memStr = execute("sysctl -n hw.memsize").trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Double(memStr) {
            report.totalMemoryGB = bytes / (1024.0 * 1024.0 * 1024.0)
        }
        
        // 3. Swap usage: total = 3072.00M  used = 2582.62M  free = 489.38M
        let swapStr = execute("sysctl vm.swapusage")
        if let regex = try? NSRegularExpression(pattern: "used\\s*=\\s*([0-9\\.]+)M") {
            let ns = swapStr as NSString
            if let match = regex.firstMatch(in: swapStr, range: NSRange(location: 0, length: ns.length)) {
                let valStr = ns.substring(with: match.range(at: 1))
                report.swapUsedMB = Double(valStr) ?? 0.0
            }
        }
        
        // 4. Listening ports via lsof
        let lsofOut = execute("lsof -iTCP -sTCP:LISTEN -n -P")
        var listeningPids: [Int: [String]] = [:]
        for line in lsofOut.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if cols.count >= 9 {
                if let pid = Int(cols[1]) {
                    let port = cols[8].components(separatedBy: ":").last ?? cols[8]
                    listeningPids[pid, default: []].append(port)
                }
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
        
        // Identify Dev Servers and potential Orphan roots
        var orphanRootPids = Set<Int>()
        
        for (pid, proc) in allProcs {
            let cmd = proc.cmd
            let lowerCmd = cmd.lowercased()
            
            // Check whitelist
            if whitelist.contains(where: { cmd.contains($0) }) {
                continue
            }
            
            // 1. Dev servers (listening on port)
            if let ports = listeningPids[pid] {
                if lowerCmd.contains("node") || lowerCmd.contains("python") || lowerCmd.contains("bun") || lowerCmd.contains("deno") || lowerCmd.contains("go") {
                    let portList = Array(Set(ports)).sorted().joined(separator: ", ")
                    var name = cmd.components(separatedBy: " ").first?.components(separatedBy: "/").last ?? "Server"
                    if lowerCmd.contains("vite") { name = "Vite" }
                    else if lowerCmd.contains("next") { name = "Next.js" }
                    else if lowerCmd.contains("nuxt") { name = "Nuxt" }
                    else if lowerCmd.contains("fastapi") || lowerCmd.contains("uvicorn") { name = "FastAPI" }
                    else if lowerCmd.contains("flask") { name = "Flask" }
                    
                    report.devServers.append(DevServerItem(
                        id: pid,
                        pid: pid,
                        name: name,
                        port: portList,
                        memMB: proc.memMB,
                        cmd: cmd
                    ))
                }
            } else if proc.ppid == 1 {
                // 2. Orphan detection (PPID == 1, not listening on port)
                let isRunner = lowerCmd.contains("node") || lowerCmd.contains("npm") || lowerCmd.contains("python") || lowerCmd.contains("uv")
                let hasSignature = mcpKeywords.contains(where: { lowerCmd.contains($0) })
                
                if isRunner && hasSignature {
                    orphanRootPids.insert(pid)
                }
            }
        }
        
        // Recursively find child processes of orphan roots (e.g. npm -> node)
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
        
        for pid in allOrphanPids {
            if let proc = allProcs[pid] {
                var cleanName = proc.cmd.components(separatedBy: " ").first?.components(separatedBy: "/").last ?? "Orphan"
                for kw in mcpKeywords {
                    if proc.cmd.contains(kw) {
                        cleanName = kw
                        break
                    }
                }
                report.orphanedMCPs.append(ProcessInfoItem(
                    id: pid,
                    pid: pid,
                    ppid: proc.ppid,
                    name: cleanName,
                    memMB: proc.memMB,
                    cmd: proc.cmd
                ))
            }
        }
        
        report.orphanedMCPs.sort { $0.memMB > $1.memMB }
        report.devServers.sort { $0.memMB > $1.memMB }
        
        return report
    }
    
    public func killProcesses(pids: [Int]) -> (killedCount: Int, freedMB: Double) {
        if pids.isEmpty { return (0, 0.0) }
        
        let report = scan()
        var freedMB: Double = 0.0
        var killedCount = 0
        
        for pid in pids {
            if let target = report.orphanedMCPs.first(where: { $0.pid == pid }) {
                freedMB += target.memMB
            } else if let dev = report.devServers.first(where: { $0.pid == pid }) {
                freedMB += dev.memMB
            }
            
            kill(pid_t(pid), SIGTERM)
            killedCount += 1
        }
        
        usleep(300_000) // 300ms
        
        // Force kill any survivors
        for pid in pids {
            if kill(pid_t(pid), 0) == 0 {
                kill(pid_t(pid), SIGKILL)
            }
        }
        
        return (killedCount, freedMB)
    }
}
