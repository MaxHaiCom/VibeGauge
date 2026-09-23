import Foundation

/// 一个会话的上下文水位：离自动压缩还有多远，今天压缩过几次。只存数字和时间，不存正文。
public struct SessionContext: Identifiable, Equatable {
    public var id: String                 // Claude = session_id；Codex = 会话文件路径
    public var tool: String               // "Claude" / "Codex"
    public var cwd: String
    public var model: String
    /// 0–100；nil = 暂时不知道（Claude 在 /compact 之后、下一次请求之前就是这样）
    public var usedPct: Double?
    public var window: Int?
    public var updatedAt: TimeInterval
    public var compactions: [Compaction] = []
    public init(id: String, tool: String, cwd: String, model: String, usedPct: Double?, window: Int?, updatedAt: TimeInterval) {
        self.id = id; self.tool = tool; self.cwd = cwd; self.model = model
        self.usedPct = usedPct; self.window = window; self.updatedAt = updatedAt
    }
}

public struct Compaction: Equatable {
    public var at: TimeInterval
    /// 压缩前后占用的 token（Claude 的 compact_boundary 给出；Codex 只知道发生了）
    public var pre: Int?
    public var post: Int?
}

/// Codex 会话文件的增量状态
struct CodexCtxState {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    /// 已读部分最后 64 字节：文件被原样长度或别的长度重写时，这里对不上 → 从头重读
    var tail = Data()
    var used: Int?
    var window: Int?
    var model = ""
    var cwd = ""
    var lastAt: TimeInterval = 0
    var compactions: [Compaction] = []
}

extension ProcessScanner {
    static let sessionActiveWindow: TimeInterval = 2 * 3600
    static let compactMarker = Data("\"subtype\":\"compact_boundary\"".utf8)
    static let codexCtxMarkers = [Data("\"token_count\"".utf8), Data("\"type\":\"compacted\"".utf8), Data("\"turn_context\"".utf8),
                                  Data("\"type\":\"session_meta\"".utf8)]

    /// Claude 日志里的 compact_boundary：压缩发生的时刻与前后 token
    static func claudeCompaction(_ data: Data) -> (id: String, event: Compaction)? {
        guard data.range(of: compactMarker) != nil,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["subtype"] as? String == "compact_boundary",
              let id = j["uuid"] as? String, let ts = Fmt.parseISODate(j["timestamp"] as? String) else { return nil }
        let meta = j["compactMetadata"] as? [String: Any] ?? [:]
        return (id, Compaction(at: ts, pre: (meta["preTokens"] as? NSNumber)?.intValue, post: (meta["postTokens"] as? NSNumber)?.intValue))
    }

    /// Codex 一行：token_count 给「这次请求」的 last_token_usage.total_tokens 与 model_context_window
    /// （水位 = 两者之比；不能用累计值，也不能自己把 input / output 相加 —— 压缩后累计值不会降）；compacted = 压缩
    static func consumeCodexContextLine(_ data: Data, into s: inout CodexCtxState) {
        guard codexCtxMarkers.contains(where: { data.range(of: $0) != nil }),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let ts = Fmt.parseISODate(j["timestamp"] as? String) ?? 0
        let payload = j["payload"] as? [String: Any] ?? [:]
        switch j["type"] as? String {
        case "compacted":
            s.compactions.append(Compaction(at: ts, pre: nil, post: nil))
            s.used = nil                                    // 压缩后旧水位作废，等下一次请求的回报
        case "turn_context", "session_meta":
            // session_meta 第一行常塞着整段系统提示词（远超 16 KB），只读文件开头取不到 cwd；在这里顺手记下
            if let m = payload["model"] as? String, !m.isEmpty { s.model = m }
            if let c = payload["cwd"] as? String, !c.isEmpty { s.cwd = c }
        case "event_msg" where payload["type"] as? String == "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            // 用量和窗口成对更新：只来了新窗口没来用量，就别拿旧用量去除新窗口
            let w = (info["model_context_window"] as? NSNumber)?.intValue
            let t = ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.intValue
            if let w, w > 0, w != s.window { s.window = w; if t == nil { s.used = nil } }
            if let t, t >= 0 {
                s.used = t
                s.lastAt = max(s.lastAt, ts)
            }
        default: break
        }
    }

    /// 从上次读到的位置接着读；文件变小，或已读部分的末尾对不上（原样长度 / 变长重写）= 被重写，从头来
    static func refreshCodexCtx(path: String, from old: CodexCtxState) -> CodexCtxState {
        var st = old
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size < st.size { st = CodexCtxState() }
        else if st.offset > 0, let fh = FileHandle(forReadingAtPath: path) {
            let n = UInt64(st.tail.count)
            try? fh.seek(toOffset: st.offset - n)
            if (try? fh.read(upToCount: Int(n))) != st.tail { st = CodexCtxState() }
            try? fh.close()
        }
        if size > st.offset, let fh = FileHandle(forReadingAtPath: path) {
            var s2 = st
            if let end = try? LineReader.read(fh, from: st.offset, to: size, { line, _ in consumeCodexContextLine(line, into: &s2) }) {
                s2.offset = end
                let n = min(end, 64)
                try? fh.seek(toOffset: end - n)
                s2.tail = (try? fh.read(upToCount: Int(n))) ?? Data()
                st = s2
            }
            try? fh.close()
        }
        st.size = size
        return st
    }

    func scanSessions(now: TimeInterval = Date().timeIntervalSince1970) -> [SessionContext] {
        var out: [SessionContext] = []
        let startOfToday = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970

        // Claude：状态栏桥接按 session_id 存的水位；压缩记录来自今日用量那趟读到的 compact_boundary
        let rows = (readJSON("\(home)/.config/vibegauge/claude-sessions.json")?["sessions"] as? [String: Any]) ?? [:]
        for (sid, v) in rows {
            guard let r = v as? [String: Any], let at = (r["at"] as? NSNumber)?.doubleValue, now - at < Self.sessionActiveWindow else { continue }
            var s = SessionContext(id: sid, tool: "Claude", cwd: r["cwd"] as? String ?? "", model: r["model"] as? String ?? "",
                                   usedPct: (r["used_pct"] as? NSNumber)?.doubleValue, window: (r["window"] as? NSNumber)?.intValue, updatedAt: at)
            // 压缩记录按状态栏给的 transcript_path 精确对上；老数据没有这个字段才按文件名猜
            let state = (r["transcript"] as? String).flatMap { fileStates[$0] } ?? fileStates.first { $0.key.hasSuffix("/\(sid).jsonl") }?.value
            s.compactions = state?.compactions.values
                .filter { $0.at >= startOfToday }.sorted { $0.at < $1.at } ?? []
            out.append(s)
        }

        // Codex：近 2 小时改过的会话文件，从上次读到的位置接着读
        var seen = Set<String>()
        for f in codexSessionFiles(modifiedWithin: Self.sessionActiveWindow) {
            seen.insert(f.path)
            let st = Self.refreshCodexCtx(path: f.path, from: codexCtxStates[f.path] ?? CodexCtxState())
            codexCtxStates[f.path] = st
            guard st.used != nil || !st.compactions.isEmpty else { continue }   // 压缩后到下次回报之间显示「—」
            var s = SessionContext(id: f.path, tool: "Codex", cwd: st.cwd.isEmpty ? (sessionCwd(of: f.path) ?? "") : st.cwd, model: st.model,
                                   usedPct: st.used.flatMap { u in st.window.map { Double(u) / Double($0) * 100 } }, window: st.window,
                                   updatedAt: st.lastAt > 0 ? st.lastAt : f.mtime)
            s.compactions = st.compactions.filter { $0.at >= startOfToday }
            out.append(s)
        }
        codexCtxStates = codexCtxStates.filter { seen.contains($0.key) }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// 在等你处理的会话（来自 Claude Code 的观察型 Hook；只有事件类型、时间、会话 ID、目录、工具名）
public struct PendingSession: Identifiable, Equatable {
    public enum Kind: Equatable { case permission, input }
    public var id: String
    public var kind: Kind
    public var since: TimeInterval
    public var tool: String
    public var cwd: String
}

extension ProcessScanner {
    /// 会话在 Hook 最后一次记录之后，日志又写了东西 = 已经往下走了（按了 Esc、强退后重开…这些都不发 Hook 事件）
    static let pendingActivitySlack: TimeInterval = 30
    static let pendingKeep: TimeInterval = 12 * 3600

    /// 只显示确认过的等待：收到 Claude Code 自己的 permission_prompt 通知的待批准调用，或 idle/elicitation 的等输入。
    /// 光有 PermissionRequest 不算 —— 可能被别的 Hook 自动处理，也可能批准后工具还在跑（批准本身没有 Hook 事件）。
    static func parsePending(_ json: [String: Any]?, now: TimeInterval,
                             lastWrite: (String) -> TimeInterval? = { _ in nil }) -> [PendingSession] {
        let rows = json?["sessions"] as? [String: Any] ?? [:]
        return rows.compactMap { sid, v -> PendingSession? in
            guard let r = v as? [String: Any], let at = (r["at"] as? NSNumber)?.doubleValue, at.isFinite, now - at < pendingKeep else { return nil }
            if let tp = r["transcript_path"] as? String, let m = lastWrite(tp), m > at + pendingActivitySlack { return nil }
            let cwd = r["cwd"] as? String ?? ""
            let calls = (r["calls"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
                .filter { $0["state"] as? String == "permission" }
                .compactMap { c -> (since: TimeInterval, tool: String)? in
                    (c["since"] as? NSNumber).map { ($0.doubleValue, c["tool"] as? String ?? "") } }
            if let first = calls.min(by: { $0.since < $1.since }) {
                return PendingSession(id: sid, kind: .permission, since: first.since, tool: first.tool, cwd: cwd)
            }
            if let since = (r["input"] as? NSNumber)?.doubleValue {
                return PendingSession(id: sid, kind: .input, since: since, tool: "", cwd: cwd)
            }
            return nil
        }.sorted { $0.since < $1.since }
    }

    /// Hook 关了就不读（残留文件不再展示、不再提醒）
    func scanPending(now: TimeInterval = Date().timeIntervalSince1970) -> [PendingSession] {
        guard StatuslineBridge.shared.hooksConnected() else { return [] }
        return Self.parsePending(readJSON("\(home)/.config/vibegauge/claude-waiting.json"), now: now) { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970
        }
    }
}
