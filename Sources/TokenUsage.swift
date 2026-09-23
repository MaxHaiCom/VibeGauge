import Foundation

// Token 遥测：Claude 会话增量解析（requestId 去重）、按项目归因、各 CLI 今日用量
extension ProcessScanner {
    func sessionCwd(of path: String) -> String? {
        if let c = fileCwdCache[path] { return c.isEmpty ? nil : c }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let head = String(decoding: (try? fh.read(upToCount: 16384)) ?? Data(), as: UTF8.self)
        var found = ""
        for line in head.split(separator: "\n").prefix(12) {
            guard let data = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let c = j["cwd"] as? String, !c.isEmpty { found = c; break }
            if let p = j["payload"] as? [String: Any], let c = p["cwd"] as? String, !c.isEmpty { found = c; break }
        }
        fileCwdCache[path] = found
        return found.isEmpty ? nil : found
    }
    // MARK: Token 遥测（增量解析，requestId 去重）

    func parseAssistantLine(_ line: Substring) -> InteractionRecord? {
        guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\":"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let model = msg["model"] as? String ?? ""
        if model.contains("synthetic") { return nil }
        let id = (json["requestId"] as? String) ?? (msg["id"] as? String) ?? (json["uuid"] as? String) ?? UUID().uuidString
        let inp = usage["input_tokens"] as? Int ?? 0
        let cRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        let out = usage["output_tokens"] as? Int ?? 0
        let thinking = (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0
        return InteractionRecord(
            id: id, model: model, timestamp: parseISO(json["timestamp"] as? String) ?? 0,
            contextTokens: inp + cRead + cCreate, cacheReadTokens: cRead, outputTokens: out, thinkingTokens: thinking
        )
    }

    /// jsonl 是 append-only：只解析上次 offset 之后新增的完整行；文件变小则整体重解析
    func refreshFileState(path: String, mtime: TimeInterval, size: UInt64) -> FileParseState {
        var state = fileStates[path] ?? FileParseState()
        if state.mtime == mtime && state.size == size { return state }

        guard let fh = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? fh.close() }
        // 变小、或前 256 字节指纹变了 = 被截断重写 / 替换 → 整体重解析（正常 append 两者都不变）
        let head = (try? fh.read(upToCount: 256)) ?? Data()
        if size < state.size || head != state.head { state = FileParseState() }
        state.head = head
        do { try fh.seek(toOffset: state.parsedOffset) } catch { return state }
        let data = fh.readDataToEndOfFile()

        if let lastNL = data.lastIndex(of: 0x0A) {
            let chunk = data[data.startIndex...lastNL]
            let text = String(decoding: chunk, as: UTF8.self)   // lossy：坏字节只毁一行，不丢整块
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if var rec = parseAssistantLine(line) {
                    if rec.timestamp == 0 { rec.timestamp = mtime }
                    state.turns[rec.id] = rec   // 同 requestId 后写覆盖前写（usage 相同）
                }
            }
            state.parsedOffset += UInt64(chunk.count)
        }
        state.mtime = mtime
        state.size = size
        fileStates[path] = state
        return state
    }

    public func scanTokens() -> TokenStats {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let projectsDir = "\(home)/.claude/projects"
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: projectsDir) else {
            // 没装 Claude Code：Claude 这边没东西，但只用 Codex 的人照样要看到按项目归因
            fileStates = [:]
            var s = TokenStats()
            var byProject: [String: ProjectUsage] = [:]
            mergeCodexProjects(into: &byProject, startOfToday: Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            s.todayByProject = byProject.values.sorted { $0.ctx > $1.ctx }
            return s
        }

        let horizon = now - 24.0 * 3600.0
        var seen = Set<String>()
        var byId: [String: InteractionRecord] = [:]   // 跨文件再去重（--fork-session 会把历史复制进新文件）
        var idPath: [String: String] = [:]            // 这轮最终算在哪个文件上 → 用来归因到项目目录
        while let el = en.nextObject() as? String {
            guard el.hasSuffix(".jsonl") else { continue }
            let path = "\(projectsDir)/\(el)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            let mtime = mod.timeIntervalSince1970
            guard mtime > horizon else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            seen.insert(path)
            for (id, rec) in refreshFileState(path: path, mtime: mtime, size: size).turns {
                if let old = byId[id], old.timestamp >= rec.timestamp { continue }
                byId[id] = rec
                idPath[id] = path
            }
        }
        fileStates = fileStates.filter { seen.contains($0.key) }
        let all = byId.values

        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var s = TokenStats()
        for t in all where t.timestamp >= startOfToday {
            s.todayTurns += 1
            s.todayContext += Int64(t.contextTokens)
            s.todayCacheRead += Int64(t.cacheReadTokens)
            s.todayOutput += Int64(t.outputTokens)
            s.todayThinking += Int64(t.thinkingTokens)
        }
        s.recentInteractions = Array(all.sorted { $0.timestamp > $1.timestamp }.prefix(3))

        // 按项目归因：Claude 这边用每轮所属文件的 cwd
        var byProject: [String: ProjectUsage] = [:]
        for (id, t) in byId where t.timestamp >= startOfToday {
            guard let path = idPath[id], let cwd = sessionCwd(of: path) else { continue }
            var p = byProject[cwd] ?? ProjectUsage(path: cwd)
            p.turns += 1
            p.ctx += Int64(t.contextTokens)
            p.out += Int64(t.outputTokens)
            p.think += Int64(t.thinkingTokens)
            if !p.clis.contains("Claude") { p.clis.append("Claude") }
            byProject[cwd] = p
        }
        mergeCodexProjects(into: &byProject, startOfToday: startOfToday)
        s.todayByProject = byProject.values.sorted { $0.ctx > $1.ctx }
        return s
    }

    /// Codex 的今日用量按会话文件的 cwd 归并。口径与 codexUsageToday 一致：
    /// `total_token_usage` 是**该会话累计**，每个文件取最后一条非空的再相加。
    func mergeCodexProjects(into byProject: inout [String: ProjectUsage], startOfToday: TimeInterval) {
        let now = Date().timeIntervalSince1970
        for (path, _) in codexSessionFiles(modifiedWithin: now - startOfToday) {
            guard let cwd = sessionCwd(of: path),
                  let u = codexFileUsage(path: path, startOfToday: startOfToday) else { continue }
            var p = byProject[cwd] ?? ProjectUsage(path: cwd)
            p.turns += u.requests
            p.ctx += u.ctx
            p.out += u.out
            p.think += u.think
            if !p.clis.contains("Codex") { p.clis.append("Codex") }
            byProject[cwd] = p
        }
    }

    // MARK: 各 CLI 今日用量

    /// Codex：`token_count` 事件的 `info.total_token_usage` 是**该会话的累计值** → 每个会话文件取最后一条非空的，再跨文件相加。
    /// 跨零点继续的会话：减掉零点前最后一条累计，只算今天的量。
    func codexUsageToday(startOfToday: TimeInterval) -> CLIUsage {
        var u = CLIUsage(name: "Codex")
        var seen = Set<String>()
        for (path, mtime) in codexSessionFiles(modifiedWithin: Date().timeIntervalSince1970 - startOfToday) {
            seen.insert(path)
            guard let one = codexFileUsage(path: path, mtime: mtime, startOfToday: startOfToday) else { continue }
            u.ctx += one.ctx
            u.cacheRead += one.cacheRead
            u.out += one.out
            u.think += one.think
            u.requests += one.requests
        }
        codexUsageCache = codexUsageCache.filter { seen.contains($0.key) }
        if !u.hasTokens { u.note = L("今日无调用", "No calls today") }
        return u
    }

    /// 单个 Codex 会话文件的累计用量（`total_token_usage` 是该会话累计 → 取最后一条非空的）。
    /// 按 CLI 汇总与按项目归因共用这一份，口径不会分叉。
    /// 今天的量：total_token_usage 是**会话累计**，跨零点继续的会话要减掉零点前最后一条累计（见 codexPreMidnight）。
    /// 请求数只数今天的 token_count 事件。
    func codexFileUsage(path: String, mtime: TimeInterval? = nil,
                                startOfToday: TimeInterval = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) -> CLIUsage? {
        let mt = mtime ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970
        guard let mt = mt else { return nil }
        if let c = codexUsageCache[path], c.mtime == mt, c.day == startOfToday { return c.usage }
        var acc = CLIUsage(name: "Codex")
        let text = readTail(path, maxBytes: 256 * 1024)
        let events = text.components(separatedBy: "\n").compactMap(Self.codexTokenEvent)
        if let last = events.last {
            let base = codexPreMidnight(path: path, startOfToday: startOfToday)
            acc.ctx = max(0, last.usage.ctx - base.ctx)               // input 已含 cached
            acc.cacheRead = max(0, last.usage.cacheRead - base.cacheRead)
            acc.out = max(0, last.usage.out - base.out)
            acc.think = max(0, last.usage.think - base.think)
        }
        // 同一份累计快照会被重复写入（额度刷新时）：累计值变了才算一次请求
        var prev: (Int64, Int64)? = nil
        acc.requests = events.filter { e in
            defer { prev = (e.usage.ctx, e.usage.out) }
            return e.ts >= startOfToday && prev.map { $0 != (e.usage.ctx, e.usage.out) } ?? true
        }.count
        codexUsageCache[path] = (mt, startOfToday, acc)
        return acc
    }

    /// 一行 token_count 事件 → (时刻, 会话累计)；不是这种行就 nil
    static func codexTokenEvent(_ line: String) -> (ts: TimeInterval, usage: CLIUsage)? {
        guard line.contains("\"type\":\"token_count\""), !line.contains("\"info\":null"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = findTokenInfoStatic(json),
              let t = info["total_token_usage"] as? [String: Any] else { return nil }
        func n64(_ k: String) -> Int64 { Int64((t[k] as? NSNumber)?.intValue ?? 0) }
        var u = CLIUsage(name: "Codex")
        u.ctx = n64("input_tokens"); u.cacheRead = n64("cached_input_tokens")
        u.out = n64("output_tokens"); u.think = n64("reasoning_output_tokens")
        return (Fmt.parseISODate(json["timestamp"] as? String ?? "") ?? 0, u)
    }

    /// 零点前最后一条会话累计（跨零点继续的会话，今天的量要减掉它）。每个文件每天只找一次：
    /// 会话今天才开始（第一行就在零点后）→ 0，不扫；否则分块扫整个文件，不整个读进内存。
    func codexPreMidnight(path: String, startOfToday: TimeInterval) -> CLIUsage {
        if let b = codexBaseline[path], b.day == startOfToday { return b.usage }
        var base = CLIUsage(name: "Codex")
        guard let fh = FileHandle(forReadingAtPath: path) else { return base }
        defer { try? fh.close() }
        let head = String(decoding: (try? fh.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        let firstTS = head.split(separator: "\n").first.flatMap { line -> TimeInterval? in
            guard let d = String(line).data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return Fmt.parseISODate(j["timestamp"] as? String ?? "")
        }
        // 首行（session_meta 常带整段指令，可能远超 4KB）读不出时间 → 不敢假设是今天开始的，老老实实扫一遍
        if firstTS.map({ $0 < startOfToday }) ?? true {
            try? fh.seek(toOffset: 0)
            var carry = ""
            scan: while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty {
                let lines = (carry + String(decoding: chunk, as: UTF8.self)).components(separatedBy: "\n")
                carry = lines.last ?? ""
                for l in lines.dropLast() {
                    guard let e = Self.codexTokenEvent(l) else { continue }
                    if e.ts >= startOfToday { break scan }     // 事件按时间追加：过了零点就不用再往下读
                    base = e.usage
                }
            }
        }
        codexBaseline[path] = (startOfToday, base)
        return base
    }

    func findTokenInfo(_ x: Any) -> [String: Any]? { Self.findTokenInfoStatic(x) }

    static func findTokenInfoStatic(_ x: Any) -> [String: Any]? {
        guard let d = x as? [String: Any] else { return nil }
        if d["total_token_usage"] != nil { return d }
        for v in d.values { if let r = findTokenInfoStatic(v) { return r } }
        return nil
    }

    /// Grok：`signals.json` 只有 `turnCount` 与当前上下文占用，没有累计 token
    func grokUsageToday(startOfToday: TimeInterval) -> CLIUsage {
        var u = CLIUsage(name: "Grok")
        let fm = FileManager.default
        let root = "\(home)/.grok/sessions"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else {
            u.note = L("本地无 token 统计", "No local token stats")
            return u
        }
        for d in dirs {
            guard let subs = try? fm.contentsOfDirectory(atPath: "\(root)/\(d)") else { continue }
            for sub in subs {
                let path = "\(root)/\(d)/\(sub)/signals.json"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date,
                      mod.timeIntervalSince1970 >= startOfToday,
                      let j = readJSON(path) else { continue }
                u.turns += (j["turnCount"] as? NSNumber)?.intValue ?? 0
            }
        }
        u.note = u.turns > 0 ? L("本地无 token 统计，仅轮次", "No local token stats; turns only") : L("今日无调用", "No calls today")
        return u
    }

    public func scanCLIUsage(claude: TokenStats) -> [CLIUsage] {
        lock.lock(); defer { lock.unlock() }
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var claudeRow = CLIUsage(name: "Claude Code")
        claudeRow.requests = claude.todayTurns
        claudeRow.ctx = claude.todayContext
        claudeRow.cacheRead = claude.todayCacheRead
        claudeRow.out = claude.todayOutput
        claudeRow.think = claude.todayThinking
        if !claudeRow.hasTokens { claudeRow.note = L("今日无调用", "No calls today") }

        var gemini = CLIUsage(name: "Gemini")
        gemini.note = L("本地无 token 统计（额度见上）", "No local token stats (see quota above)")      // conversations 是 SQLite，无 token 字段

        return [claudeRow, codexUsageToday(startOfToday: startOfToday), grokUsageToday(startOfToday: startOfToday), gemini]
    }
}
