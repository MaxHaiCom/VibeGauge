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
        case "turn_context", "session_meta":
            // session_meta 第一行常塞着整段系统提示词（远超 16 KB），只读文件开头取不到 cwd；在这里顺手记下
            if let m = payload["model"] as? String, !m.isEmpty { s.model = m }
            if let c = payload["cwd"] as? String, !c.isEmpty { s.cwd = c }
        case "event_msg" where payload["type"] as? String == "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            if let w = (info["model_context_window"] as? NSNumber)?.intValue, w > 0 { s.window = w }
            if let last = info["last_token_usage"] as? [String: Any], let t = (last["total_tokens"] as? NSNumber)?.intValue {
                s.used = t
                s.lastAt = max(s.lastAt, ts)
            }
        default: break
        }
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
            s.compactions = fileStates.first { $0.key.hasSuffix("/\(sid).jsonl") }?.value.compactions.values
                .filter { $0.at >= startOfToday }.sorted { $0.at < $1.at } ?? []
            out.append(s)
        }

        // Codex：近 2 小时改过的会话文件，从上次读到的位置接着读
        var seen = Set<String>()
        for f in codexSessionFiles(modifiedWithin: Self.sessionActiveWindow) {
            seen.insert(f.path)
            var st = codexCtxStates[f.path] ?? CodexCtxState()
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size < st.size { st = CodexCtxState() }          // 文件变小 = 被重写，从头来
            if size > st.offset, let fh = FileHandle(forReadingAtPath: f.path) {
                var s2 = st
                if let end = try? LineReader.read(fh, from: st.offset, to: size, { line, _ in Self.consumeCodexContextLine(line, into: &s2) }) {
                    s2.offset = end
                    st = s2
                }
                try? fh.close()
            }
            st.size = size
            codexCtxStates[f.path] = st
            guard let used = st.used else { continue }
            var s = SessionContext(id: f.path, tool: "Codex", cwd: st.cwd.isEmpty ? (sessionCwd(of: f.path) ?? "") : st.cwd, model: st.model,
                                   usedPct: st.window.map { Double(used) / Double($0) * 100 }, window: st.window,
                                   updatedAt: st.lastAt > 0 ? st.lastAt : f.mtime)
            s.compactions = st.compactions.filter { $0.at >= startOfToday }
            out.append(s)
        }
        codexCtxStates = codexCtxStates.filter { seen.contains($0.key) }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
}
