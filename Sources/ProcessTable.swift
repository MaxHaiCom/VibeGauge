import Foundation

// 进程表：会话判定、孤儿识别用的服务/白名单规则、命令行脱敏（只读，不杀进程；杀进程在 Reaper.swift）
extension ProcessScanner {
    func launchdProtectedTokens() -> [(token: String, label: String)] {
        let now = Date().timeIntervalSince1970
        if let c = launchdCache, now - c.at < 300 { return c.tokens }
        var out: [(String, String)] = []
        let fm = FileManager.default
        let dirs = ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".plist") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(n)")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? n
                var args: [String] = []
                if let prog = plist["Program"] as? String { args.append(prog) }
                if let pa = plist["ProgramArguments"] as? [String] { args.append(contentsOf: pa) }
                for a in args {
                    let base = String(a.split(separator: "/").last ?? "")
                    if a.hasPrefix("-") || base.isEmpty || interpreters.contains(base) { continue }
                    if a.count < 6 { continue }              // 太短的实参当特征会误伤
                    out.append((a, label))
                }
            }
        }
        launchdCache = (now, out)
        return out
    }

    /// 命令行脱敏后再给人看（自测输出会被贴进公开 Issue）：认证类参数的值、URL 里的账号密码、像 key 的长串一律打码
    static func redactCommand(_ cmd: String) -> String {
        let secretFlag = #"(?i)^--?[a-z0-9_-]*(key|token|secret|password|passwd|auth|credential)[a-z0-9_-]*$"#
        var out: [String] = []
        var hideNext = false
        for raw in cmd.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            var t = raw
            let bare = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if hideNext {
                t = "***"
                // 「Authorization: Bearer <凭据>」是三个词：盖掉 Bearer / Basic 之后还要再盖下一个
                hideNext = ["bearer", "basic", "token"].contains(bare)
            }
            else if t.range(of: secretFlag, options: .regularExpression) != nil { hideNext = true }
            else if bare.hasPrefix("authorization") || bare.hasPrefix("x-api-key") || bare.hasPrefix("api-key:") {
                // -H "Authorization: Bearer xxx" / Authorization:Bearer_xxx：冒号后面的全盖，值若在下一个词也盖
                if let colon = t.firstIndex(of: ":") {
                    let rest = t[t.index(after: colon)...]
                    t = String(t[...colon]) + (rest.isEmpty ? "" : "***")
                    hideNext = rest.isEmpty || ["bearer", "basic", "token"].contains(rest.lowercased())
                } else { hideNext = true }
            }
            else if let eq = t.firstIndex(of: "="), String(t[..<eq]).range(of: #"(?i)(key|token|secret|password|passwd|auth|credential)"#, options: .regularExpression) != nil {
                t = String(t[...eq]) + "***"
            }
            t = t.replacingOccurrences(of: #"://[^/@\s]+@"#, with: "://***@", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\b(sk|ghp|gho|xox[a-z]|glpat|AIza|AKIA)[A-Za-z0-9_\-]{8,}"#, with: "***", options: .regularExpression)
            out.append(t)
        }
        return out.joined(separator: " ")
    }

    /// "The system has 25769803776 (1572864 pages with a page size of 16384)." → 16384
    static func memoryPressurePageSize(_ output: String) -> Double? {
        guard let r = output.range(of: #"page size of (\d+)"#, options: .regularExpression) else { return nil }
        return Double(output[r].split(separator: " ").last ?? "")
    }

    /// 是不是 MCP 服务进程：脚本运行时（node / npm / python / uv）+ 明确的 MCP 特征。
    /// 只在 ~/.npm/_npx 里不算 —— 用 npx 起的普通后台工具关掉终端后同样 ppid=1、不监听端口，被当孤儿杀掉就是误杀。
    /// 官方服务端包是 @modelcontextprotocol/server-*（不含 "mcp" 子串），要单独认；
    /// 但只认 server-：用官方 SDK 写的**客户端**程序路径里也有 @modelcontextprotocol/sdk，那不是该收割的东西。
    static func isMCPServerCommand(_ lowerCmd: String, serviceKeys: [String] = []) -> Bool {
        let runner = ["node", "npm", "python", "uv"].contains { lowerCmd.contains($0) }
        let signature = (serviceKeys + ["mcp", "modelcontextprotocol/server-"]).contains { lowerCmd.contains($0) }
        return runner && signature
    }

    // MARK: 会话判定（用户交互终端 vs 子脚本/MCP）

    static func isShellWrapper(_ cmd: String) -> Bool {
        cmd.hasPrefix("/bin/zsh") || cmd.hasPrefix("/bin/bash") || cmd.hasPrefix("zsh") || cmd.hasPrefix("bash") || cmd.hasPrefix("sh ")
    }

    static func binName(_ cmd: String) -> String {
        String(executablePath(cmd).split(separator: "/").last ?? "")
    }

    /// 命令行的第一个 token = 可执行文件路径。
    /// 探测必须只看这个，不能在整条命令行里找子串：任何 shell 命令（包括别人 grep 这些名字）都会命中，造成误判。
    static func executablePath(_ cmd: String) -> String {
        String(cmd.split(separator: " ").first ?? "")
    }

    /// 某个 App/CLI 是否真的在跑：看可执行文件路径，且跳过 shell 包装器
    static func isRunning(_ cmd: String, bundle: String, bins: [String]) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) { return false }
        let exe = executablePath(t).lowercased()
        if !bundle.isEmpty, exe.contains(bundle) { return true }
        let bin = String(exe.split(separator: "/").last ?? "")
        return bins.contains(bin)
    }

    public static func isClaudeCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("mcp-server") || t.contains("grep") { return false }
        return binName(t) == "claude"
    }

    public static func isCodexCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) { return false }
        if t.contains("mcp-server") || t.contains("ChatGPT for Chrome") || t.contains("chrome-extension") || t.contains("ssh") || t.contains("grep") { return false }
        // 同一会话派生出来的组件，不是独立会话
        if t.contains("codex-darwin") || t.contains("/vendor/") || t.contains("codex-path") || t.contains("/plugins/cache/") || t.contains("cua_node") { return false }
        let bin = binName(t)
        if bin == "codex" || bin == "codex.js" { return true }
        let parts = t.split(separator: " ")
        if bin.contains("node"), parts.count > 1, parts[1].contains("codex") { return true }
        return false
    }

    public static func isAgyCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("grep") { return false }
        for sub in ["agy-routed", "agy-batch", "agy-review", "agy-video"] where t.contains(sub) { return false }
        return binName(t) == "agy"
    }

    public static func isGrokCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("mcp-server") || t.contains("grep") { return false }
        return binName(t) == "grok"
    }

    // MARK: 进程表

    struct RawProc {
        let pid: Int
        let ppid: Int
        let memMB: Double
        let cmd: String
    }

    /// 一批 pid 的 cwd（一次 lsof 拿完）
    func cwds(of pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let out = execute("lsof -p \(pids.map(String.init).joined(separator: ",")) -a -d cwd -Fpn 2>/dev/null")
        var map: [Int: String] = [:]
        var cur = 0
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("p") { cur = Int(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), cur != 0 { map[cur] = String(line.dropFirst()) }
        }
        return map
    }

    /// 进程已运行秒数（ps etime）
    func ages(of pids: [Int]) -> [Int: Int] {
        guard !pids.isEmpty else { return [:] }
        let out = execute("ps -o pid=,etime= -p \(pids.map(String.init).joined(separator: ","))")
        var map: [Int: Int] = [:]
        for line in out.components(separatedBy: "\n") {
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard f.count >= 2, let pid = Int(f[0]) else { continue }
            // etime: [[dd-]hh:]mm:ss
            var secs = 0
            let main = f[1].split(separator: "-")
            if main.count == 2 { secs += (Int(main[0]) ?? 0) * 86400 }
            let parts = (main.last ?? "").split(separator: ":").map { Int($0) ?? 0 }
            if parts.count == 3 { secs += parts[0] * 3600 + parts[1] * 60 + parts[2] }
            else if parts.count == 2 { secs += parts[0] * 60 + parts[1] }
            map[pid] = secs
        }
        return map
    }

    struct SessionCounts {
        var claude = 0, codex = 0, agy = 0, grok = 0
        var ollama = false, cursor = false, lmStudio = false
        var pids: [CLIKind: [Int]] = [:]
        var mem: [Int: Double] = [:]
    }

    func readProcs() -> [Int: RawProc] {
        var procs: [Int: RawProc] = [:]
        let out = execute("ps -axo pid,ppid,rss,command")
        for line in out.components(separatedBy: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let parts = t.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]), let rssKB = Double(parts[2]) else { continue }
            procs[pid] = RawProc(pid: pid, ppid: ppid, memMB: rssKB / 1024.0, cmd: String(parts[3]))
        }
        return procs
    }

    enum CLIKind { case claude, codex, agy, grok }

    func countSessions(_ procs: [Int: RawProc]) -> SessionCounts {
        var c = SessionCounts()

        // 第一遍：命中的进程
        var matched: [Int: CLIKind] = [:]
        for p in procs.values {
            if ProcessScanner.isRunning(p.cmd, bundle: "/cursor.app/", bins: ["cursor"]) { c.cursor = true }
            if ProcessScanner.isRunning(p.cmd, bundle: "/ollama.app/", bins: ["ollama"]) { c.ollama = true }
            if ProcessScanner.isRunning(p.cmd, bundle: "lm studio.app/", bins: ["lm studio", "lmstudio"]) { c.lmStudio = true }
            guard p.ppid != 1 else { continue }
            if ProcessScanner.isClaudeCLISession(cmd: p.cmd) { matched[p.pid] = .claude }
            else if ProcessScanner.isCodexCLISession(cmd: p.cmd) { matched[p.pid] = .codex }
            else if ProcessScanner.isAgyCLISession(cmd: p.cmd) { matched[p.pid] = .agy }
            else if ProcessScanner.isGrokCLISession(cmd: p.cmd) { matched[p.pid] = .grok }
        }

        // 第二遍：一个会话 = 一棵进程树的根。CLI 会派生同名子进程（node 包装器 → 原生二进制 → 插件宿主），
        // 祖先已命中的就不再单独算一个会话，否则一个 Codex 会话会被数成 3 个。
        for (pid, kind) in matched {
            var cur = procs[pid]?.ppid ?? 1
            var hops = 0
            var nested = false
            while cur > 1, hops < 30 {
                if matched[cur] != nil { nested = true; break }
                cur = procs[cur]?.ppid ?? 1
                hops += 1
            }
            if nested { continue }
            c.pids[kind, default: []].append(pid)
            c.mem[pid] = procs[pid]?.memMB ?? 0
            switch kind {
            case .claude: c.claude += 1
            case .codex: c.codex += 1
            case .agy: c.agy += 1
            case .grok: c.grok += 1
            }
        }
        // Grok 双保险：~/.grok/active_sessions.json 里存活的 pid
        if c.grok == 0,
           let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.grok/active_sessions.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            c.grok = json.filter { ($0["pid"] as? Int).map { kill(pid_t($0), 0) == 0 } ?? false }.count
        }
        return c
    }
}
