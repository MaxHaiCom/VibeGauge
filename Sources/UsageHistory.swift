import Foundation
import CryptoKit
import os

/// 只缓存用量字段，不保存对话正文；按文件保留贡献，才能在日志重写后撤销旧账。
public final class UsageHistory {
    public static let shared = UsageHistory()

    public struct ModelTotals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var tokenTotal: Int64 { ctx + out }
        mutating func add(_ other: ModelTotals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think
        }
    }

    public struct Totals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var turns = 0
        public var sessions = 0
        public var models: [String: ModelTotals] = [:]
        public var tokenTotal: Int64 { ctx + out }
        public var newInput: Int64 { max(0, ctx - cacheRead - cacheWrite) }
        public var cacheTotal: Int64 { cacheRead + cacheWrite }

        mutating func add(_ record: Record) {
            let u = record.usage
            ctx += u.ctx; cacheRead += u.cacheRead; cacheWrite += u.cacheWrite
            out += u.out; think += u.think; turns += 1
            models[record.model, default: ModelTotals()].add(u)
        }
        mutating func merge(_ other: Totals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think; turns += other.turns
            for (model, usage) in other.models { models[model, default: ModelTotals()].add(usage) }
        }
    }

    public struct Day: Codable, Equatable, Identifiable {
        public var id: String { date }
        public let date: String
        public var sources: [String: Totals]
        public var total: Totals { sources.values.reduce(into: Totals()) { $0.merge($1) } }
    }

    public struct Snapshot: Equatable {
        public var days: [Day] = []
        public var dailyTokens: [String: Int64] = [:]
        public var totals: [String: Totals] = [:]
        public var aggregate = Totals()
        public var earliestDate: String?
        public var activeDays = 0
        public var isScanning = false
        public var processedFiles = 0
        public var totalFiles = 0
        public var error = ""
        public var sourceNotes: [String: String] = [:]
        public var hasPriceTable = false
        public var priceCurrency = ""
        public var cost: Double?
        public var costBySource: [String: Double] = [:]
        public var unpricedModels = 0
        public var unpricedBySource: [String: Int] = [:]
        public var cumulativeTurns = 0
        public var skippedRecords = 0
        public var capturedAt: TimeInterval = 0
        /// 近 7 天每个钟点（本地时区）的调用次数，键 = 来源（Claude / Codex / API · 厂商），"*" = 全部 CLI
        public var hourCounts: [String: [Double]] = [:]
        public var tokenTotal: Int64 { aggregate.tokenTotal }
        /// 某个平台的作息画像：优先用它自己的日志，没有（Gemini / Grok 等）就用你整体的作息
        public func activityProfile(for name: String) -> ActivityProfile? {
            (hourCounts[name] ?? hourCounts["API · " + name]).flatMap(ActivityProfile.init(hourCounts:))
                ?? hourCounts["*"].flatMap(ActivityProfile.init(hourCounts:))
        }
        public var ctx: Int64 { aggregate.ctx }
        public var cacheRead: Int64 { aggregate.cacheRead }
        public var cacheHitRate: Double? { ctx > 0 ? Double(cacheRead) / Double(ctx) : nil }
        public init() {}
    }

    /// 经记账代理的上游（"API · GLM" 这类）：同一请求多半已在 CLI 日志里，不进总数
    public static func isProxySource(_ source: String) -> Bool { source.hasPrefix("API") }

    /// 同值同档，零日留空；档位只由非零日的最近秩分位数决定。
    public static func levels(_ values: [Int64]) -> [Int] {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return values.map { _ in 0 } }
        let thresholds = (1...4).map { positive[max(0, Int(ceil(Double(positive.count) * Double($0) / 5)) - 1)] }
        return values.map { value in value <= 0 ? 0 : 1 + thresholds.filter { value > $0 }.count }
    }

    public static func dayKey(timestamp: TimeInterval, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func codexLastTokenUsage(_ fields: [String: Int64]) -> ModelTotals {
        ModelTotals(ctx: fields["input_tokens"] ?? 0, cacheRead: fields["cached_input_tokens"] ?? 0,
                    cacheWrite: fields["cache_write_input_tokens"] ?? 0, out: fields["output_tokens"] ?? 0,
                    think: fields["reasoning_output_tokens"] ?? 0)
    }

    /// 累计值回退时只建立新基线；不把负差变成零，也不把整个重置值再记一次。
    public static func codexCumulativeDelta(previous: [String: Int64]?, current: [String: Int64]) -> ModelTotals? {
        var delta: [String: Int64] = [:]
        for key in tokenKeys {
            let now = current[key] ?? 0, old = previous?[key] ?? 0
            guard now >= old else { return nil }
            delta[key] = now - old
        }
        let result = codexLastTokenUsage(delta)
        return result.tokenTotal > 0 ? result : nil
    }

    /// 同一累计快照可被额度刷新重复写入；不同请求即便单次 token 完全相同，也不能被去重。
    static func codexUsage(info: [String: Any], previous: inout [String: Int64]?) -> (usage: ModelTotals, cumulative: Bool)? {
        let total = tokenFields(info["total_token_usage"])
        let last = tokenFields(info["last_token_usage"])
        let old = previous
        if let total { previous = total }
        if let total, total == old { return nil }
        if let last { return (codexLastTokenUsage(last), false) }
        guard let total, let delta = codexCumulativeDelta(previous: old, current: total) else { return nil }
        return (delta, true)
    }

    struct Record: Codable, Equatable {
        var id: String
        var source: String
        var timestamp: TimeInterval
        var model: String
        var usage: ModelTotals
        var cumulative = false
    }

    /// 文件内同 requestId 后写覆盖前写，跨文件再选 timestamp 最新的，和即时扫描器口径一致。
    static func deduplicateClaude(_ files: [String: [Record]]) -> [String: Record] {
        var result: [String: Record] = [:]
        for path in files.keys.sorted() {
            var latest: [String: Record] = [:]
            for record in files[path] ?? [] { latest[record.id] = record }
            for (id, record) in latest {
                if let old = result[id], old.timestamp >= record.timestamp { continue }
                result[id] = record
            }
        }
        return result
    }

    /// 每个日志文件的贡献：近 `recentWindow` 内是逐条记录（去重、作息画像要用），更早的折成「天 × 来源」汇总。
    /// 按文件存而不是全局存：日志被重写时能精确撤销这个文件的全部贡献，会话数也还能按文件算。
    struct FileState: Codable {
        var source: String
        var model = "?"
        var size: UInt64 = 0
        var mtime: TimeInterval = 0
        var offset: UInt64 = 0
        var head = ""
        var previousTotal: [String: Int64]?
        var records: [String: Record] = [:]
        var skipped = 0
        var folded: [String: [String: Totals]] = [:]     // 天 → 来源 → 汇总
        var foldedCumulative = 0

        init(source: String) { self.source = source }
        // v3 缓存没有 folded 字段：缺了就当空，别让整个历史解码失败
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "?"
            size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            mtime = try c.decodeIfPresent(TimeInterval.self, forKey: .mtime) ?? 0
            offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
            head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
            previousTotal = try c.decodeIfPresent([String: Int64].self, forKey: .previousTotal)
            records = try c.decodeIfPresent([String: Record].self, forKey: .records) ?? [:]
            skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
            folded = try c.decodeIfPresent([String: [String: Totals]].self, forKey: .folded) ?? [:]
            foldedCumulative = try c.decodeIfPresent(Int.self, forKey: .foldedCumulative) ?? 0
        }
    }
    /// v4：历史存档（已删日志的 FileState、各文件的 folded）和可重建的扫描进度在同一文件里，
    /// 但解析器升级（parserVersion 变）只重读还在的日志，已删日志的历史不动 —— 存档不因扫描缓存失效而丢。
    struct DiskCache: Codable {
        static let currentVersion = 4
        var version = currentVersion
        var parserVersion = UsageHistory.parserVersion
        var files: [String: FileState] = [:]
        /// 已折叠的 Claude 请求 ID → 归属文件。续接/分叉会话会把同一请求复制进新文件，靠它跨文件去重。
        var claudeIds: [String: String] = [:]
        var updatedAt: TimeInterval = 0

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            parserVersion = try c.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 1   // v3 与解析器 1 同口径
            files = try c.decodeIfPresent([String: FileState].self, forKey: .files) ?? [:]
            claudeIds = try c.decodeIfPresent([String: String].self, forKey: .claudeIds) ?? [:]
            updatedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        }
    }
    /// 改了日志解析口径就 +1：还在的日志会被重读，已删日志保留旧口径的历史（没有原文可重读）。
    static let parserVersion = 1
    /// 逐条记录保留期：作息画像要近 7 天的时间戳，多留 1 天余量。
    static let recentWindow: TimeInterval = 8 * 86400

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.haifeng.vibegauge.usage-history", qos: .utility)
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "usage-history")
    private let home: String
    private let cachePath: String
    private var timer: DispatchSourceTimer?
    private var started = false
    private var loaded = false
    private var errors: Set<String> = []
    private var cache = DiskCache()
    /// 缓存是更新版本的 App 写的（用户降级了）：只在内存里汇总，绝不写回去覆盖它
    private var readOnly = false
    /// 自测注入时间，别让「8 天前」随真实日期漂移
    var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
    private var cached = Snapshot()
    /// 缓存约 30MB：有变化才写、且至少隔 30 分钟。崩溃丢掉的只是 offset 进度，
    /// 下次从旧 offset 重读，记录按 requestId/行偏移做键，重复读不会重复计数。
    private var dirty = false
    private var savedAt: TimeInterval = 0
    private static let saveEvery: TimeInterval = 1800
    private let iso = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private static let tokenKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let codexMarkers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, cachePath: String? = nil) {
        self.home = home
        self.cachePath = cachePath ?? "\(home)/.config/vibegauge/usage-daily.json"
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: 300)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 锁只保护快照交换，不参与读盘、解码、归并或落盘。
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 自测的临时日志树也走真实增量路径，和定时扫描共用串行队列。
    func scanNowForTesting() { worker.sync { scan() } }

    private func scan() {
        errors = []
        publishProgress(0, total: 0)
        loadCache()
        let paths = discoverFiles()
        publishProgress(0, total: paths.count)
        for (index, item) in paths.enumerated() {
            autoreleasepool { process(item.path, source: item.source) }
            publishProgress(index + 1, total: paths.count)
        }
        fold(livePaths: Set(paths.map(\.path)), now: clock())
        var result = summarize()
        result.processedFiles = paths.count
        result.totalFiles = paths.count
        for source in ["Claude", "Codex"] where !paths.contains(where: { $0.source == source }) {
            result.sourceNotes[source] = result.totals[source] == nil ? L("未检测到本机会话日志", "No local session logs found") : L("日志已移除，显示已缓存历史", "Logs removed; showing cached history")
        }
        cache.updatedAt = clock()
        if dirty, cache.updatedAt - savedAt >= Self.saveEvery {
            saveCache()
            dirty = false
            savedAt = cache.updatedAt
        }
        result.capturedAt = cache.updatedAt
        result.error = errors.sorted().joined(separator: "；")
        lock.lock()
        let old = cached
        cached = result
        lock.unlock()
        withExtendedLifetime(old) {}
        log.notice("历史汇总完成：\(paths.count) 文件，\(result.days.count) 天，跳过 \(result.skippedRecords) 条不完整记录")
    }

    private func discoverFiles() -> [(path: String, source: String)] {
        let fm = FileManager.default
        var result: [(path: String, source: String)] = []
        for (suffix, source) in [(".claude/projects", "Claude"), (".codex/sessions", "Codex")] {
            let root = URL(fileURLWithPath: "\(home)/\(suffix)")
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in
                self.errors.insert(L("部分日志目录无法读取，汇总可能不完整", "Some log directories could not be read; summary may be incomplete"))
                return true
            }) else { errors.insert(L("日志目录无法读取", "Log directory unavailable")); continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                result.append((url.path, source))
            }
        }
        let api = "\(home)/.config/vibegauge/api-calls.jsonl"
        if fm.fileExists(atPath: api) { result.append((api, "API")) }
        return result.sorted { $0.path < $1.path }
    }

    private func process(_ path: String, source: String) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let mod = attrs[.modificationDate] as? Date, let size = (attrs[.size] as? NSNumber)?.uint64Value else { throw CocoaError(.fileReadUnknown) }
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let head = try fh.read(upToCount: 256) ?? Data()
            var state = cache.files[path] ?? FileState(source: source)
            let oldHead = Self.fingerprint(Data(head.prefix(Int(min(256, state.size)))))
            let rewritten = state.offset > size || size < state.size || (!state.head.isEmpty && oldHead != state.head)
                || (size == state.size && mod.timeIntervalSince1970 != state.mtime)
            if state.source != source || rewritten { forget(path); state = FileState(source: source) }
            if state.size == size, state.mtime == mod.timeIntervalSince1970, state.head == Self.fingerprint(head) { return }
            try fh.seek(toOffset: state.offset)
            try readNewLines(fh, state: &state, size: size)
            state.head = Self.fingerprint(head)
            state.size = size; state.mtime = mod.timeIntervalSince1970
            cache.files[path] = state
            dirty = true
        } catch { errors.insert(L("部分日志无法读取，保留上次汇总并等待重试", "Some logs could not be read; keeping the previous summary and retrying")) }
    }

    private func readNewLines(_ fh: FileHandle, state: inout FileState, size: UInt64) throws {
        var remaining = size - state.offset
        var pending = Data()
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let end = pending.index(after: lastNL)
            let complete = pending[pending.startIndex..<end]
            var offset = state.offset
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                autoreleasepool { consume(Data(line), offset: offset, state: &state) }
                offset += UInt64(line.count + 1)
            }
            state.offset = offset
            pending = Data(pending[end...])
        }
    }

    private func consume(_ data: Data, offset: UInt64, state: inout FileState) {
        // 大多数行是工具结果和正文，先筛字段名，避免把数 GB 无关 JSON 全部解码。
        if state.source == "Claude", data.range(of: Self.usageMarker) == nil { return }
        if state.source == "Codex", !Self.codexMarkers.contains(where: { data.range(of: $0) != nil }) { return }
        guard !data.isEmpty else { return }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { state.skipped += 1; return }
        if state.source == "Claude" {
            guard j["type"] as? String == "assistant", let msg = j["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { return }
            let model = msg["model"] as? String ?? "?"
            guard !model.contains("synthetic") else { return }
            guard let ts = timestamp(j["timestamp"]),
                  let id = (j["requestId"] as? String) ?? (msg["id"] as? String) ?? (j["uuid"] as? String), !id.isEmpty,
                  let input = number(usage["input_tokens"]), let output = number(usage["output_tokens"]) else { state.skipped += 1; return }
            let read = number(usage["cache_read_input_tokens"]) ?? 0
            let write = number(usage["cache_creation_input_tokens"]) ?? 0
            let think = number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0
            state.records[id] = Record(id: id, source: "Claude", timestamp: ts, model: model.isEmpty ? "?" : model,
                                       usage: ModelTotals(ctx: input + read + write, cacheRead: read, cacheWrite: write, out: output, think: think))
        } else if state.source == "Codex" {
            guard let payload = j["payload"] as? [String: Any] else { return }
            if ["turn_context", "session_meta"].contains(j["type"] as? String ?? "") {
                if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
                return
            }
            guard j["type"] as? String == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else { return }
            guard let parsed = Self.codexUsage(info: info, previous: &state.previousTotal) else { return }
            guard let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            let model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.model
            let id = String(offset)
            state.records[id] = Record(id: id, source: "Codex", timestamp: ts, model: model, usage: parsed.usage, cumulative: parsed.cumulative)
        } else {
            guard let ts = timestamp(j["epoch"]) ?? timestamp(j["ts"]), let host = j["host"] as? String,
                  let ctx = number(j["ctx"]), let out = number(j["out"]) else { state.skipped += 1; return }
            let provider = (j["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            let model = (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            let id = String(offset)
            state.records[id] = Record(id: id, source: "API · " + provider, timestamp: ts, model: model,
                                       usage: ModelTotals(ctx: ctx, cacheRead: number(j["cache_read"]) ?? 0,
                                                          cacheWrite: number(j["cache_write"]) ?? 0, out: out, think: number(j["think"]) ?? 0))
        }
    }

    /// 把旧记录折成按天汇总：日志已删的整个文件折掉，还在的只折 recentWindow 之前的。
    /// ponytail: 折叠时按当时时区分天，之后改时区不会重新分桶；要精确再存 UTC 小时桶。
    func fold(livePaths: Set<String>, now: TimeInterval) {
        let cutoff = now - Self.recentWindow
        for path in cache.files.keys.sorted() {
            guard var state = cache.files[path] else { continue }
            let live = livePaths.contains(path)
            let old = state.records.values.filter { !live || $0.timestamp < cutoff }
            guard !old.isEmpty else { continue }
            for record in old.sorted(by: { $0.timestamp < $1.timestamp }) {
                state.records[record.id] = nil
                let day = Self.dayKey(timestamp: record.timestamp)
                if record.source == "Claude" {
                    // 另一个文件已经折过同一请求 → 这份是复制品：不计量，但这个会话当天出现过（会话数口径不变）
                    if let owner = cache.claudeIds[record.id], owner != path {
                        if state.folded[day]?[record.source] == nil { state.folded[day, default: [:]][record.source] = Totals() }
                        continue
                    }
                    cache.claudeIds[record.id] = path
                }
                state.folded[day, default: [:]][record.source, default: Totals()].add(record)
                if record.cumulative { state.foldedCumulative += 1 }
            }
            cache.files[path] = state
            dirty = true
        }
    }

    /// 文件被重写 / 要重读：撤销它登记过的 Claude 请求 ID。
    /// ponytail: 别的文件里因这些 ID 被当复制品跳过的记录不会补回（Claude 日志只追加，实际不会发生）。
    private func forget(_ path: String) {
        cache.claudeIds = cache.claudeIds.filter { $0.value != path }
    }

    private static func tokenFields(_ raw: Any?) -> [String: Int64]? {
        guard let fields = raw as? [String: Any], fields["input_tokens"] is NSNumber, fields["output_tokens"] is NSNumber else { return nil }
        var result: [String: Int64] = [:]
        for key in tokenKeys {
            let n = (fields[key] as? NSNumber)?.int64Value ?? 0
            guard n >= 0 else { return nil }
            result[key] = n
        }
        return result
    }
    private func number(_ raw: Any?) -> Int64? {
        guard let n = raw as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.int64Value
    }
    private func timestamp(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue > 0 && n.doubleValue.isFinite ? n.doubleValue : nil }
        guard var text = raw as? String else { return nil }
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: text[range].prefix(4)) }
        return (iso.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970
    }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 历史里有已删日志的账，丢了就找不回来。所以：读不了的挪到旁边不覆盖，
    /// 旧版本先留备份再升级，新版本写的只读不写。
    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: cachePath) else { return }
        let decoded: DiskCache
        do {
            decoded = try JSONDecoder().decode(DiskCache.self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
        } catch {
            setAside("corrupt-\(Int(clock()))")
            errors.insert(L("历史缓存无法读取，已另存并重新汇总", "History cache unreadable; kept a copy and rebuilding summary"))
            return
        }
        switch decoded.version {
        case DiskCache.currentVersion:
            cache = decoded
        case 3:
            // v3 的逐条记录原样可用；留一份原文件，下次保存时写成 v4（会把旧记录折叠）
            let backup = (cachePath as NSString).deletingPathExtension + ".v3.json"
            if !fm.fileExists(atPath: backup) {
                do { try fm.copyItem(atPath: cachePath, toPath: backup) } catch {
                    readOnly = true
                    errors.insert(L("历史缓存备份失败，本次不改写", "History cache backup failed; not rewriting it this session"))
                }
            }
            cache = decoded
            cache.version = DiskCache.currentVersion
            dirty = true
        case let v where v > DiskCache.currentVersion:
            readOnly = true
            errors.insert(L("历史缓存来自更新版本的 VibeGauge，本次只读不改写", "History cache was written by a newer VibeGauge; reading only"))
        default:
            setAside("v\(decoded.version)")
            errors.insert(L("历史缓存版本过旧，已另存并重新汇总", "History cache format too old; kept a copy and rebuilding summary"))
        }
        // 解析口径变了：还在的日志重读，已删日志保留（没有原文可重读）
        if cache.parserVersion != Self.parserVersion {
            for path in cache.files.keys where fm.fileExists(atPath: path) {
                forget(path); cache.files[path] = nil
            }
            cache.parserVersion = Self.parserVersion
            dirty = true
        }
    }
    private func setAside(_ tag: String) {
        let dest = (cachePath as NSString).deletingPathExtension + ".\(tag).json"
        do { try FileManager.default.moveItem(atPath: cachePath, toPath: dest) } catch { readOnly = true }
    }
    private func saveCache() {
        guard !readOnly else { return }
        do {
            let url = URL(fileURLWithPath: cachePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath)
        } catch { errors.insert(L("历史缓存保存失败，重启后需重新汇总", "History cache could not be saved; restart will rebuild the summary")) }
    }
    private func readJSON(_ path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return json
        } catch { errors.insert(L("价目表无法读取，未计入成本", "Price table could not be read; cost omitted")); return nil }
    }
    private func publishProgress(_ processed: Int, total: Int) {
        lock.lock()
        cached.isScanning = true; cached.processedFiles = processed; cached.totalFiles = total
        lock.unlock()
    }

    private func summarize() -> Snapshot {
        var result = Snapshot()
        var buckets: [String: [String: Totals]] = [:]
        var sessions: [String: Set<String>] = [:]
        var dailySessions: [String: [String: Set<String>]] = [:]
        var claudeFiles: [String: [Record]] = [:]
        var records: [Record] = []
        // 旧日志被清理后仍保留历史；同一路径重写时 process 已替换该文件的全部贡献。
        for (path, state) in cache.files {
            result.skippedRecords += state.skipped
            result.cumulativeTurns += state.foldedCumulative
            if state.source == "Claude" {
                // 已被别的文件折叠过的请求，是复制品
                claudeFiles[path] = state.records.values.filter { cache.claudeIds[$0.id].map { $0 == path } ?? true }
            } else { records.append(contentsOf: state.records.values) }
            for record in state.records.values {
                let day = Self.dayKey(timestamp: record.timestamp)
                sessions[record.source, default: []].insert(path)
                dailySessions[day, default: [:]][record.source, default: []].insert(path)
            }
            for (day, bySource) in state.folded {
                for (source, totals) in bySource {
                    buckets[day, default: [:]][source, default: Totals()].merge(totals)
                    result.totals[source, default: Totals()].merge(totals)
                    sessions[source, default: []].insert(path)
                    dailySessions[day, default: [:]][source, default: []].insert(path)
                }
            }
        }
        records.append(contentsOf: Self.deduplicateClaude(claudeFiles).values)
        for record in records {
            let day = Self.dayKey(timestamp: record.timestamp)
            buckets[day, default: [:]][record.source, default: Totals()].add(record)
            result.totals[record.source, default: Totals()].add(record)
            if record.cumulative { result.cumulativeTurns += 1 }
        }
        let now = clock()
        for (source, recs) in Dictionary(grouping: records, by: \.source) {
            result.hourCounts[source] = ActivityProfile.hourCounts(recs.map(\.timestamp), now: now)
        }
        result.hourCounts["*"] = ActivityProfile.hourCounts(records.filter { !Self.isProxySource($0.source) }.map(\.timestamp), now: now)
        for source in result.totals.keys { result.totals[source]?.sessions = sessions[source]?.count ?? 0 }
        for day in buckets.keys {
            for source in buckets[day]!.keys { buckets[day]?[source]?.sessions = dailySessions[day]?[source]?.count ?? 0 }
        }
        result.days = buckets.keys.sorted().map { Day(date: $0, sources: buckets[$0]!) }
        result.earliestDate = result.days.first?.date
        // 经记账代理的 API 调用不计入总数与热力图：代理前面挂的多半就是 Claude Code / Codex，
        // 同一次请求在 CLI 日志里已经记过一次，再加就是重复计数。API 只单独出卡片。
        func cliTokens(_ d: Day) -> Int64 {
            d.sources.filter { !Self.isProxySource($0.key) }.values.reduce(0) { $0 + $1.tokenTotal }
        }
        result.dailyTokens = Dictionary(uniqueKeysWithValues: result.days.map { ($0.date, cliTokens($0)) })
        result.activeDays = result.dailyTokens.values.filter { $0 > 0 }.count
        for (source, totals) in result.totals where !Self.isProxySource(source) { result.aggregate.merge(totals) }
        let price = readJSON("\(home)/.config/vibegauge/prices.json").map { ProcessScanner.PriceTable(json: $0) } ?? ProcessScanner.PriceTable()
        result.hasPriceTable = !price.isEmpty
        result.priceCurrency = price.currency
        for (source, totals) in result.totals {
            // 总成本和总 token 同一口径：经代理的调用多半已在 CLI 日志里，只算各自来源，不进总数
            let inTotal = !Self.isProxySource(source)
            for (model, usage) in totals.models {
                if let cost = price.cost(model: model, ctx: usage.ctx, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, out: usage.out) {
                    if inTotal { result.cost = (result.cost ?? 0) + cost }
                    result.costBySource[source, default: 0] += cost
                } else {
                    if inTotal { result.unpricedModels += 1 }
                    result.unpricedBySource[source, default: 0] += 1
                }
            }
        }
        return result
    }
}

public extension Fmt {
    static func tokens(_ count: Int64) -> String {
        let d = Double(count)
        if isChineseUI {
            if count >= 100_000_000 { return String(format: "%.2f 亿", d / 1e8) }
            if count >= 10_000_000 { return String(format: "%.0f 万", d / 1e4) }
            if count >= 10_000 { return String(format: "%.1f 万", d / 1e4) }
        } else {
            if count >= 1_000_000_000 { return String(format: "%.2fB", d / 1e9) }
            if count >= 1_000_000 { return String(format: "%.1fM", d / 1e6) }
            if count >= 100_000 { return String(format: "%.0fk", d / 1e3) }      // 142k，不要 142.0k
            if count >= 10_000 { return String(format: "%.1fk", d / 1e3) }
        }
        return String(count)
    }
}
