import Foundation

public struct ServiceGroup: Identifiable {
    public var id: String { serviceName }
    public let serviceName: String
    public var processCount: Int
    public var totalMemMB: Double
    public var pids: [Int]
}

public struct TokenStats {
    public var latestModel: String = ""
    public var latestContext: Int = 0
    public var latestCacheHitRate: Double = 0.0
    public var latestOutput: Int = 0
    public var latestThinking: Int = 0
    public var latestSecondsAgo: Int = 0
    public var latestTimestamp: TimeInterval = 0
    public var isActive: Bool = false
    
    public var turns5h: Int = 0
    public var context5h: Int64 = 0
    public var output5h: Int64 = 0
    
    public var todayTurns: Int = 0
    public var todayContext: Int64 = 0
    public var todayCacheRead: Int64 = 0
    public var todayOutput: Int64 = 0
    public var todayThinking: Int64 = 0
    public var todayCacheHitRate: Double {
        todayContext > 0 ? (Double(todayCacheRead) / Double(todayContext)) * 100.0 : 0.0
    }
    
    // 服务端真实下发的订阅配额百分比 (Claude Max/Pro 独有)
    public var fiveHourPct: Int? = nil
    public var sevenDayPct: Int? = nil
}

public struct DetectedLLMRuntime: Identifiable {
    public var id: String { name }
    public let name: String
    public let provider: String
    public let isRunning: Bool
    public let tier: String
    public let detail: String
    public var fiveHourPct: Int? = nil
    public var sevenDayPct: Int? = nil
    public var secondaryPoolName: String = ""
    public var secondaryFiveHourPct: Int? = nil
    public var secondarySevenDayPct: Int? = nil
    public var isFullWidth: Bool = false
    public var quotaSubtitle: String = ""
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
    
    // 全景主流大模型检测 (Claude / Gemini / OpenAI / Ollama / Cursor 等)
    public var detectedLLMs: [DetectedLLMRuntime] = []
    
    // Vibe Coding 专属环境状态
    public var activeClaudeCount: Int = 0
    public var activeCodexCount: Int = 0
    public var activeAgyCount: Int = 0
    public var activeGrokCount: Int = 0
    public var activeMCPProcessCount: Int = 0
    public var activeMCPTotalMemMB: Double = 0.0
    
    // Token 与 Prompt Cache 实时与累计遥测
    public var tokens: TokenStats = TokenStats()
    
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
    
    private var lastCumulativeScanTime: TimeInterval = 0
    private var cachedTokenStats = TokenStats()
    
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
    
    // MARK: - 实时会话判定探针 (精准区分用户 CLI 交互终端 vs 子脚本/MCP/插件)
    public static func isClaudeCLISession(cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/bin/zsh") || trimmed.hasPrefix("/bin/bash") || trimmed.hasPrefix("zsh") || trimmed.hasPrefix("bash") || trimmed.hasPrefix("sh ") { return false }
        if trimmed.contains("mcp-server") || trimmed.contains("grep") { return false }
        let parts = trimmed.split(separator: " ")
        guard let first = parts.first else { return false }
        let bin = String(first.split(separator: "/").last ?? "")
        return bin == "claude"
    }

    public static func isCodexCLISession(cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/bin/zsh") || trimmed.hasPrefix("/bin/bash") || trimmed.hasPrefix("zsh") || trimmed.hasPrefix("bash") || trimmed.hasPrefix("sh ") { return false }
        if trimmed.contains("mcp-server") || trimmed.contains("ChatGPT for Chrome") || trimmed.contains("chrome-extension") || trimmed.contains("ssh") || trimmed.contains("grep") { return false }
        let parts = trimmed.split(separator: " ")
        guard let first = parts.first else { return false }
        let bin = String(first.split(separator: "/").last ?? "")
        if bin == "codex" || bin == "codex.js" {
            return true
        }
        if bin.contains("node") && parts.count > 1 {
            let arg1 = String(parts[1])
            if arg1.contains("codex") && !arg1.contains("mcp-server") {
                return true
            }
        }
        return false
    }

    public static func isAgyCLISession(cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/bin/zsh") || trimmed.hasPrefix("/bin/bash") || trimmed.hasPrefix("zsh") || trimmed.hasPrefix("bash") || trimmed.hasPrefix("sh ") { return false }
        if trimmed.contains("agy-routed") || trimmed.contains("agy-batch") || trimmed.contains("agy-review") || trimmed.contains("agy-video") || trimmed.contains("grep") { return false }
        let parts = trimmed.split(separator: " ")
        guard let first = parts.first else { return false }
        let bin = String(first.split(separator: "/").last ?? "")
        return bin == "agy"
    }

    public static func isGrokCLISession(cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/bin/zsh") || trimmed.hasPrefix("/bin/bash") || trimmed.hasPrefix("zsh") || trimmed.hasPrefix("bash") || trimmed.hasPrefix("sh ") { return false }
        if trimmed.contains("mcp-server") || trimmed.contains("grep") { return false }
        let parts = trimmed.split(separator: " ")
        guard let first = parts.first else { return false }
        let bin = String(first.split(separator: "/").last ?? "")
        return bin == "grok"
    }
    
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
                    report.compressorGB = (pages * 16384.0) / (1024.0 * 1024.0)
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
        var hasCursor = false
        var hasOllama = false
        var hasLMStudio = false
        
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
                
                // 检查主流模型与工具进程
                if lowerCmd.contains("cursor.app") || (lowerCmd.contains("/cursor") && !lowerCmd.contains("cursoruiviewservice")) {
                    hasCursor = true
                }
                if lowerCmd.contains("ollama") {
                    hasOllama = true
                }
                if lowerCmd.contains("lmstudio") || lowerCmd.contains("lm studio") {
                    hasLMStudio = true
                }
                
                // 统计正在活跃的 AI 会话
                if ppid != 1 {
                    if ProcessScanner.isClaudeCLISession(cmd: cmd) {
                        report.activeClaudeCount += 1
                    } else if ProcessScanner.isCodexCLISession(cmd: cmd) {
                        report.activeCodexCount += 1
                    } else if ProcessScanner.isAgyCLISession(cmd: cmd) {
                        report.activeAgyCount += 1
                    } else if ProcessScanner.isGrokCLISession(cmd: cmd) {
                        report.activeGrokCount += 1
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
        
        // 探活 Grok 活跃会话 (~/.grok/active_sessions.json 双重保障)
        if report.activeGrokCount == 0 {
            let grokSessionsPath = "\(home)/.grok/active_sessions.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: grokSessionsPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for s in json {
                    if let pid = s["pid"] as? Int, kill(pid_t(pid), 0) == 0 {
                        report.activeGrokCount += 1
                    }
                }
            }
        }
        
        // 9. 甄别断链孤儿进程
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
        
        // 递归追踪孤儿的子进程
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
        
        // 10. Token & Prompt Cache 实时与累计遥测
        report.tokens = scanTokens()
        
        // 11. 多模型全景感知与各模型专属额度汇聚
        report.detectedLLMs = detectAllLLMRuntimes(
            claudeCount: report.activeClaudeCount,
            codexCount: report.activeCodexCount,
            agyCount: report.activeAgyCount,
            grokCount: report.activeGrokCount,
            hasOllama: hasOllama,
            hasCursor: hasCursor,
            hasLMStudio: hasLMStudio,
            tokens: report.tokens
        )
        
        return report
    }
    
    // 档位与鉴权特征判别
    private func getClaudeTier() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeJson = "\(home)/.claude.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeJson)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oa = json["oauthAccount"] as? [String: Any] {
            let rateTier = oa["organizationRateLimitTier"] as? String ?? ""
            if rateTier.contains("max") {
                return "Max 5x"
            } else if rateTier.contains("team") {
                return "Team"
            } else if rateTier.contains("pro") {
                return "Pro"
            }
            let billing = oa["billingType"] as? String ?? ""
            if billing.contains("subscription") {
                return "Pro"
            }
        }
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil {
            return "API Key"
        }
        return "Max 5x"
    }
    
    private func getCodexTier() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let authPath = "\(home)/.codex/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let toks = json["tokens"] as? [String: Any],
               let idTok = toks["id_token"] as? String {
                let parts = idTok.split(separator: ".")
                if parts.count >= 2 {
                    var payloadStr = String(parts[1])
                    let rem = payloadStr.count % 4
                    if rem > 0 { payloadStr += String(repeating: "=", count: 4 - rem) }
                    if let pData = Data(base64Encoded: payloadStr),
                       let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
                       let authObj = pJson["https://api.openai.com/auth"] as? [String: Any],
                       let plan = authObj["chatgpt_plan_type"] as? String {
                        if plan.contains("prolite") || plan.contains("5x") || plan.contains("pro") {
                            return "Pro 5x"
                        } else if plan.contains("team") {
                            return "Team"
                        } else if plan.contains("plus") {
                            return "Plus"
                        }
                    }
                }
            }
            let mode = json["auth_mode"] as? String ?? ""
            if mode == "chatgpt" { return "Pro 5x" }
            if mode == "api_key" { return "API Key" }
        }
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil {
            return "API Key"
        }
        return "Pro 5x"
    }
    
    private func getGeminiTier() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tokenPath = "\(home)/.gemini/antigravity-cli/antigravity-oauth-token"
        
        if FileManager.default.fileExists(atPath: tokenPath) {
            // 1. 检查是否存在 Google One AI Premium / Gemini Advanced 双额度池 (Gemini + 3P Claude/GPT)
            let cachePath = "\(home)/.cache/agy-hud/quota_cache.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pools = json["pools"] as? [String: Any] {
                if pools["3p"] != nil || pools["gemini"] != nil {
                    return "Advanced"
                }
            }
            
            // 2. 检查 OAuth 认证类型 (consumer 即 Google One 个人高级订阅)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let method = json["auth_method"] as? String, method == "consumer" {
                    return "Advanced"
                }
            }
            return "Advanced"
        }
        
        if ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil {
            return "API Key"
        }
        return "Free"
    }

    // 提取 Gemini 多额度池 (原生池与 Claude/GPT 三方池)
    private func getGeminiDualPools() -> (native5h: Int?, nativeW: Int?, tp5h: Int?, tpW: Int?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cachePath = "\(home)/.cache/agy-hud/quota_cache.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pools = json["pools"] as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        
        func extractPct(_ dict: [String: Any]?, key: String) -> Int? {
            guard let sub = dict?[key] as? [String: Any],
                  let rf = sub["remaining_fraction"] as? Double else {
                return nil
            }
            return max(0, min(100, Int(round((1.0 - rf) * 100.0))))
        }
        
        let g = pools["gemini"] as? [String: Any]
        let tp = pools["3p"] as? [String: Any]
        
        let g5h = extractPct(g, key: "5h")
        let gw = extractPct(g, key: "weekly")
        let tp5h = extractPct(tp, key: "5h")
        let tpw = extractPct(tp, key: "weekly")
        
        return (g5h, gw, tp5h, tpw)
    }

    private func getGrokTier() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.grok/settings_cache.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payloadStr = json["payload"] as? String,
           let pData = payloadStr.data(using: .utf8),
           let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let settings = pJson["settings"] as? [String: Any] {
            if let tierDisplay = settings["subscription_tier_display"] as? String, !tierDisplay.isEmpty {
                if tierDisplay.contains("Premium") || tierDisplay.contains("SuperGrok") {
                    return "SuperGrok"
                }
                return tierDisplay
            }
        }
        
        let authPath = "\(home)/.grok/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, v) in json {
                if let dict = v as? [String: Any] {
                    if let mode = dict["auth_mode"] as? String, mode == "oidc" {
                        return "SuperGrok"
                    }
                }
            }
        }
        
        if ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil || ProcessInfo.processInfo.environment["GROK_API_KEY"] != nil {
            return "API Key"
        }
        
        return "SuperGrok"
    }

    // 多模型自动探针
    private func detectAllLLMRuntimes(
        claudeCount: Int,
        codexCount: Int,
        agyCount: Int,
        grokCount: Int,
        hasOllama: Bool,
        hasCursor: Bool,
        hasLMStudio: Bool,
        tokens: TokenStats
    ) -> [DetectedLLMRuntime] {
        var list: [DetectedLLMRuntime] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // 1. Claude
        let claudeInstalled = FileManager.default.fileExists(atPath: "\(home)/.claude.json")
        if claudeCount > 0 || claudeInstalled {
            list.append(DetectedLLMRuntime(
                name: "Claude",
                provider: "",
                isRunning: claudeCount > 0,
                tier: getClaudeTier(),
                detail: "\(claudeCount) 会话",
                fiveHourPct: tokens.fiveHourPct,
                sevenDayPct: tokens.sevenDayPct,
                quotaSubtitle: ""
            ))
        }
        
        // 2. Codex
        let codexInstalled = FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json")
        if codexCount > 0 || codexInstalled {
            list.append(DetectedLLMRuntime(
                name: "Codex",
                provider: "",
                isRunning: codexCount > 0,
                tier: getCodexTier(),
                detail: "\(codexCount) 会话",
                quotaSubtitle: "OpenAI · 会话就绪"
            ))
        }
        
        // 3. Gemini (支持原生与 Claude/GPT 三方双额度池，独占单行通栏)
        let geminiInstalled = FileManager.default.fileExists(atPath: "\(home)/.gemini/antigravity-cli/antigravity-oauth-token")
        if agyCount > 0 || geminiInstalled {
            let dual = getGeminiDualPools()
            let hasDual = dual.tpW != nil || dual.tp5h != nil || dual.native5h != nil || dual.nativeW != nil
            list.append(DetectedLLMRuntime(
                name: "Gemini",
                provider: "",
                isRunning: agyCount > 0,
                tier: getGeminiTier(),
                detail: "\(agyCount) 会话",
                fiveHourPct: dual.native5h,
                sevenDayPct: dual.nativeW,
                secondaryPoolName: "三方 (Claude/GPT)",
                secondaryFiveHourPct: dual.tp5h,
                secondarySevenDayPct: dual.tpW,
                isFullWidth: hasDual,
                quotaSubtitle: "Agy 运行时 · 会话活跃"
            ))
        }
        
        // 4. Grok (xAI 订阅)
        let grokInstalled = FileManager.default.fileExists(atPath: "\(home)/.grok")
        if grokCount > 0 || grokInstalled {
            list.append(DetectedLLMRuntime(
                name: "Grok",
                provider: "",
                isRunning: grokCount > 0,
                tier: getGrokTier(),
                detail: "\(grokCount) 会话",
                quotaSubtitle: "xAI · grok-4.6 就绪"
            ))
        }
        
        // 5. Ollama
        if hasOllama {
            var ollamaCount = 0
            var ollamaSub = "端侧运行 · 0 额度消耗"
            if let url = URL(string: "http://127.0.0.1:11434/api/ps") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 0.3
                let sema = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["models"] as? [[String: Any]], !models.isEmpty {
                        ollamaCount = models.count
                        let names = models.compactMap { $0["name"] as? String }.joined(separator: ", ")
                        ollamaSub = "模型: \(names)"
                    }
                    sema.signal()
                }.resume()
                _ = sema.wait(timeout: .now() + 0.3)
            }
            list.append(DetectedLLMRuntime(
                name: "Ollama",
                provider: "",
                isRunning: ollamaCount > 0,
                tier: "本地",
                detail: "\(ollamaCount) 会话",
                quotaSubtitle: ollamaSub
            ))
        }
        
        // 6. Cursor
        if hasCursor {
            list.append(DetectedLLMRuntime(
                name: "Cursor",
                provider: "",
                isRunning: true,
                tier: "Pro",
                detail: "1 会话",
                quotaSubtitle: "高速池 500次/月"
            ))
        }
        
        // 7. LM Studio
        if hasLMStudio {
            list.append(DetectedLLMRuntime(
                name: "LM Studio",
                provider: "",
                isRunning: true,
                tier: "本地",
                detail: "1 会话",
                quotaSubtitle: "端侧运行 · 0 额度消耗"
            ))
        }
        
        return list
    }
    
    // 毫秒级极速探查活跃 LLM 会话状态 (用于菜单打开时的动态实时更新)
    public func scanActiveLLMs() -> [DetectedLLMRuntime] {
        let psOut = execute("ps -axo pid,ppid,command")
        let lines = psOut.components(separatedBy: "\n").dropFirst()
        
        var claudeCount = 0
        var codexCount = 0
        var agyCount = 0
        var grokCount = 0
        var hasOllama = false
        var hasCursor = false
        var hasLMStudio = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count < 3 { continue }
            guard let ppid = Int(parts[1]) else { continue }
            let cmd = String(parts[2])
            
            let lowerCmd = cmd.lowercased()
            if lowerCmd.contains("cursor.app") || (lowerCmd.contains("/cursor") && !lowerCmd.contains("cursoruiviewservice")) {
                hasCursor = true
            }
            if lowerCmd.contains("ollama") {
                hasOllama = true
            }
            if lowerCmd.contains("lmstudio") || lowerCmd.contains("lm studio") {
                hasLMStudio = true
            }
            
            if ppid != 1 {
                if ProcessScanner.isClaudeCLISession(cmd: cmd) {
                    claudeCount += 1
                } else if ProcessScanner.isCodexCLISession(cmd: cmd) {
                    codexCount += 1
                } else if ProcessScanner.isAgyCLISession(cmd: cmd) {
                    agyCount += 1
                } else if ProcessScanner.isGrokCLISession(cmd: cmd) {
                    grokCount += 1
                }
            }
        }
        
        if grokCount == 0 {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let grokSessionsPath = "\(home)/.grok/active_sessions.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: grokSessionsPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for s in json {
                    if let pid = s["pid"] as? Int, kill(pid_t(pid), 0) == 0 {
                        grokCount += 1
                    }
                }
            }
        }
        
        return detectAllLLMRuntimes(
            claudeCount: claudeCount,
            codexCount: codexCount,
            agyCount: agyCount,
            grokCount: grokCount,
            hasOllama: hasOllama,
            hasCursor: hasCursor,
            hasLMStudio: hasLMStudio,
            tokens: cachedTokenStats
        )
    }
    
    private func scanTokens() -> TokenStats {
        let now = Date().timeIntervalSince1970
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"
        guard FileManager.default.fileExists(atPath: projectsDir) else { return cachedTokenStats }
        
        let window5h = now - 5.0 * 3600.0
        let window24h = now - 24.0 * 3600.0
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: projectsDir) else { return cachedTokenStats }
        
        var recentFiles: [(path: String, mtime: TimeInterval)] = []
        while let element = enumerator.nextObject() as? String {
            if element.hasSuffix(".jsonl") {
                let fullPath = "\(projectsDir)/\(element)"
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    let mtime = modDate.timeIntervalSince1970
                    if mtime > window24h {
                        recentFiles.append((fullPath, mtime))
                    }
                }
            }
        }
        recentFiles.sort { $0.mtime > $1.mtime }
        
        var stats = TokenStats()
        
        // A. 实时提取：最新会话文件的最后一轮交互
        if let newest = recentFiles.first {
            stats.latestTimestamp = newest.mtime
            stats.latestSecondsAgo = max(0, Int(now - newest.mtime))
            if let content = try? String(contentsOfFile: newest.path, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                for line in lines.reversed() {
                    if line.contains("\"type\":\"assistant\"") && line.contains("\"usage\":") {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msg = json["message"] as? [String: Any],
                           let usage = msg["usage"] as? [String: Any] {
                            stats.latestModel = msg["model"] as? String ?? "claude"
                            let inp = usage["input_tokens"] as? Int ?? 0
                            let cRead = usage["cache_read_input_tokens"] as? Int ?? 0
                            let cCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                            let out = usage["output_tokens"] as? Int ?? 0
                            let details = usage["output_tokens_details"] as? [String: Any]
                            let thinking = details?["thinking_tokens"] as? Int ?? 0
                            
                            let totalCtx = inp + cRead + cCreate
                            stats.latestContext = totalCtx
                            stats.latestOutput = out
                            stats.latestThinking = thinking
                            stats.latestCacheHitRate = totalCtx > 0 ? (Double(cRead) / Double(totalCtx)) * 100.0 : 0.0
                            break
                        }
                    }
                }
            }
        }
        
        // B. 累计统计：每 45 秒刷新一次全量
        if now - lastCumulativeScanTime > 45.0 || cachedTokenStats.todayContext == 0 {
            lastCumulativeScanTime = now
            for file in recentFiles {
                guard let content = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
                let lines = content.components(separatedBy: "\n")
                let is5h = file.mtime > window5h
                
                for line in lines {
                    if line.contains("\"type\":\"assistant\"") && line.contains("\"usage\":") {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msg = json["message"] as? [String: Any],
                           let usage = msg["usage"] as? [String: Any] {
                            let inp = Int64(usage["input_tokens"] as? Int ?? 0)
                            let cRead = Int64(usage["cache_read_input_tokens"] as? Int ?? 0)
                            let cCreate = Int64(usage["cache_creation_input_tokens"] as? Int ?? 0)
                            let out = Int64(usage["output_tokens"] as? Int ?? 0)
                            let details = usage["output_tokens_details"] as? [String: Any]
                            let thinking = Int64(details?["thinking_tokens"] as? Int ?? 0)
                            let ctx = inp + cRead + cCreate
                            
                            stats.todayTurns += 1
                            stats.todayContext += ctx
                            stats.todayCacheRead += cRead
                            stats.todayOutput += out
                            stats.todayThinking += thinking
                            
                            if is5h {
                                stats.turns5h += 1
                                stats.context5h += ctx
                                stats.output5h += out
                            }
                        }
                    }
                }
            }
            cachedTokenStats.turns5h = stats.turns5h
            cachedTokenStats.context5h = stats.context5h
            cachedTokenStats.output5h = stats.output5h
            cachedTokenStats.todayTurns = stats.todayTurns
            cachedTokenStats.todayContext = stats.todayContext
            cachedTokenStats.todayCacheRead = stats.todayCacheRead
            cachedTokenStats.todayOutput = stats.todayOutput
            cachedTokenStats.todayThinking = stats.todayThinking
        } else {
            stats.turns5h = cachedTokenStats.turns5h
            stats.context5h = cachedTokenStats.context5h
            stats.output5h = cachedTokenStats.output5h
            stats.todayTurns = cachedTokenStats.todayTurns
            stats.todayContext = cachedTokenStats.todayContext
            stats.todayCacheRead = cachedTokenStats.todayCacheRead
            stats.todayOutput = cachedTokenStats.todayOutput
            stats.todayThinking = cachedTokenStats.todayThinking
        }
        
        // C. 读取服务端下发的真实订阅配额 (Claude Max/Pro 5h与7d配额)
        let usagePath = "\(home)/.claude/claude-usage.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: usagePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fh = json["five_hour"] as? [String: Any],
               let pct = fh["used_percentage"] as? Int {
                stats.fiveHourPct = pct
            }
            if let sd = json["seven_day"] as? [String: Any],
               let pct = sd["used_percentage"] as? Int {
                stats.sevenDayPct = pct
            }
        }
        
        return stats
    }
    
    // 毫秒级极速探查最新一轮会话遥测 (用于菜单打开时的动态实时监测)
    public func scanLatestInteraction() -> TokenStats {
        var stats = cachedTokenStats
        let now = Date().timeIntervalSince1970
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"
        guard FileManager.default.fileExists(atPath: projectsDir) else { return stats }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: projectsDir) else { return stats }
        
        var newestPath: String? = nil
        var newestMtime: TimeInterval = 0
        
        while let element = enumerator.nextObject() as? String {
            if element.hasSuffix(".jsonl") {
                let fullPath = "\(projectsDir)/\(element)"
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    let mtime = modDate.timeIntervalSince1970
                    if mtime > newestMtime {
                        newestMtime = mtime
                        newestPath = fullPath
                    }
                }
            }
        }
        
        if let path = newestPath {
            stats.latestTimestamp = newestMtime
            stats.latestSecondsAgo = max(0, Int(now - newestMtime))
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                for line in lines.reversed() {
                    if line.contains("\"type\":\"assistant\"") && line.contains("\"usage\":") {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msg = json["message"] as? [String: Any],
                           let usage = msg["usage"] as? [String: Any] {
                            stats.latestModel = msg["model"] as? String ?? "claude"
                            let inp = usage["input_tokens"] as? Int ?? 0
                            let cRead = usage["cache_read_input_tokens"] as? Int ?? 0
                            let cCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                            let out = usage["output_tokens"] as? Int ?? 0
                            let details = usage["output_tokens_details"] as? [String: Any]
                            let thinking = details?["thinking_tokens"] as? Int ?? 0
                            
                            let totalCtx = inp + cRead + cCreate
                            stats.latestContext = totalCtx
                            stats.latestOutput = out
                            stats.latestThinking = thinking
                            stats.latestCacheHitRate = totalCtx > 0 ? (Double(cRead) / Double(totalCtx)) * 100.0 : 0.0
                            break
                        }
                    }
                }
            }
        }
        return stats
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
