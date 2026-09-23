import Foundation

// API 记账：读代理写的 api-calls.jsonl / api-quota.json、价目表、限流响应头、BASE_URL 覆盖体检
extension ProcessScanner {
    // MARK: API Key 调用（读记账代理写的 api-calls.jsonl / api-quota.json）

    struct APICall {
        let ts: TimeInterval
        let host: String
        let provider: String
        let model: String
        let ctx: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let out: Int64
        let think: Int64
        let status: Int
        let ms: Int
        let key: String
        let rl: [String: String]
        /// 响应完整转发完了（旧记录没有这个字段 → 当作完整）
        var complete = true
        /// 失败：4xx/5xx、没状态，或者流式传到一半断了（状态码仍是 200）
        var failed: Bool { status >= 400 || status == 0 || !complete }
        /// 请求已完整发给上游（代理新字段 sent）。连接阶段就失败的（DNS / 拒连）没到厂商，不占套餐额度；
        /// 发出去之后才断的算到了 —— 估额度宁可偏高
        var sent = true
        /// 代理找到并完整读到了用量（parsed）。false 的调用 token 是 0 或残缺，不能当「用了 0」
        var parsed = true
    }

    /// 价目表：`~/.config/vibegauge/prices.json`，单位 = 每百万 token。
    /// ```
    /// { "_asof": "2026-09-18", "_currency": "CNY",
    ///   "glm-4.7": { "in": 0.6, "cache_read": 0.11, "cache_write": 0.6, "out": 2.2 } }
    /// ```
    /// 没这文件就不估花费 —— 价格会变，编一个假的比不显示更糟。模型名取「最长前缀命中」。
    public struct PriceTable {
        public struct Row { public var input = 0.0, cacheRead = 0.0, cacheWrite = 0.0, output = 0.0 }
        public var rows: [String: Row] = [:]
        public var currency: String = ""
        public var asOf: String = ""
        public var isEmpty: Bool { rows.isEmpty }

        public init() {}
        public init(json: [String: Any]) {
            currency = (json["_currency"] as? String) ?? "USD"
            asOf = (json["_asof"] as? String) ?? ""
            for (k, v) in json where !k.hasPrefix("_") {
                guard let d = v as? [String: Any] else { continue }
                func f(_ key: String) -> Double { (d[key] as? NSNumber)?.doubleValue ?? 0 }
                var r = Row()
                r.input = f("in"); r.output = f("out")
                r.cacheRead = d["cache_read"] == nil ? r.input : f("cache_read")
                r.cacheWrite = d["cache_write"] == nil ? r.input : f("cache_write")
                // 全 0 视为"没填价"（示例文件里的占位行不该算出 ¥0.00 的假花费）
                if r.input == 0, r.output == 0, r.cacheRead == 0, r.cacheWrite == 0 { continue }
                rows[k.lowercased()] = r
            }
        }

        func row(for model: String) -> Row? {
            let m = model.lowercased()
            if let exact = rows[m] { return exact }
            // 最长前缀命中："glm-4.7" 能覆盖 "glm-4.7-flash"；取最长的那条，避免被短名抢走
            return rows.filter { m.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
        }

        /// ctx 是「全部输入」（新鲜 + 缓存读 + 缓存写），算价时要先把缓存部分扣出来
        public func cost(model: String, ctx: Int64, cacheRead: Int64, cacheWrite: Int64, out: Int64) -> Double? {
            guard let r = row(for: model) else { return nil }
            let fresh = max(0, ctx - cacheRead - cacheWrite)
            return (Double(fresh) * r.input + Double(cacheRead) * r.cacheRead
                    + Double(cacheWrite) * r.cacheWrite + Double(out) * r.output) / 1_000_000.0
        }
    }

    /// 订阅制 Coding Plan 的「请求数」上限（不是 token）。这类套餐没有公开用量接口，
    /// 而且厂商明令禁止用非编程工具去调它的端点（会被判滥用、可能停用订阅），
    /// 所以我们既不探测、也不猜价 —— 只拿本机记账的请求数 ÷ 上限估，并在面板上标明「估算」。
    /// 上限从 ~/.config/vibegauge/plans.json 读（照官方套餐页自己填）。
    /// 套餐额度规则（plans.json 一项）。各家结构不同（调研见 docs/PROTOCOL.md「plans.json」）：
    /// 共享池每次请求记 1、共享池按模型系数扣、每个模型独立一个池；窗口有滚动、首次请求起算、每周一、订阅日四种重置方式。
    public struct PlanLimit {
        public var label: String = ""
        /// 窗口 → 上限（请求数；配了 weights 就是「系数折算后的请求数」）
        public var limits: [String: Int] = [:]
        /// 窗口 → 重置方式：rolling（默认）/ first_use / monday / subscription_day
        public var resets: [String: String] = [:]
        /// 模型名前缀 → 抵扣系数；"*" = 其余模型。没配 = 每次请求记 1
        public var weights: [String: Double] = [:]
        public var subscribedDay: Int? = nil
        public var timeZone: TimeZone = .current
        /// 独立额度的模型（前缀 → 自己的上限与重置）：这些模型的请求不进共享池
        public var modelPools: [String: PlanLimit] = [:]

        func weight(_ model: String) -> Double {
            let m = model.lowercased()
            if let w = weights.filter({ m.hasPrefix($0.key.lowercased()) && $0.key != "*" }).max(by: { $0.key.count < $1.key.count })?.value { return w }
            return weights["*"] ?? 1
        }
    }

    static let planWindows: [(key: String, seconds: Double)] = [("5h", 5 * 3600), ("weekly", 7 * 86400), ("monthly", 30 * 86400)]

    static func parsePlan(_ d: [String: Any], label: String) -> PlanLimit {
        var p = PlanLimit()
        p.label = d["plan"] as? String ?? label
        for (k, v) in d["requests"] as? [String: Any] ?? [:] { if let n = (v as? NSNumber)?.intValue, n > 0 { p.limits[k] = n } }
        for (k, v) in d["reset"] as? [String: Any] ?? [:] { if let s = v as? String { p.resets[k] = s } }
        for (k, v) in d["weights"] as? [String: Any] ?? [:] { if let n = (v as? NSNumber)?.doubleValue, n > 0 { p.weights[k] = n } }
        if let day = Fmt.parseISODate((d["subscribed_on"] as? String).map { $0 + "T00:00:00Z" }) {
            p.subscribedDay = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: Date(timeIntervalSince1970: day)).day
        }
        if let tz = (d["timezone"] as? String).flatMap(TimeZone.init(identifier:)) { p.timeZone = tz }
        for (k, v) in d["models"] as? [String: Any] ?? [:] {
            guard let md = v as? [String: Any] else { continue }
            var m = parsePlan(md, label: k)
            if md["reset"] == nil { m.resets = p.resets }
            if md["timezone"] == nil { m.timeZone = p.timeZone }
            if md["subscribed_on"] == nil { m.subscribedDay = p.subscribedDay }
            if !m.limits.isEmpty { p.modelPools[k] = m }
        }
        return p
    }

    func planLimits() -> [String: PlanLimit] {
        let path = "\(home)/.config/vibegauge/plans.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return [:] }
        let mtime = mod.timeIntervalSince1970
        if let c = planCache, c.mtime == mtime { return c.plans }
        var out: [String: PlanLimit] = [:]
        for (k, v) in readJSON(path) ?? [:] where !k.hasPrefix("_") {
            guard let d = v as? [String: Any] else { continue }
            let p = Self.parsePlan(d, label: k)
            if !p.limits.isEmpty || !p.modelPools.isEmpty { out[k] = p }
        }
        planCache = (mtime, out)
        return out
    }

    /// 滚动窗口内的请求数 → 额度窗口。重置点 = 窗口内最早那次调用 + 窗口长度（容量什么时候开始回来）
    public static func rollingWindow(_ stamps: [TimeInterval], seconds: Double, limit: Int, now: TimeInterval) -> QuotaWindow? {
        planWindow(stamps.map { ($0, 1.0) }, kind: "rolling", seconds: seconds, limit: limit, now: now)
    }

    /// 按记账估一个套餐窗口。calls = (时刻, 这次请求的抵扣系数)；
    /// rolling = 每笔满窗口时长后各自释放；first_use = 首次请求起算、到点整体刷新（下一笔请求再开新窗口）；
    /// monday = 每周一 00:00 重置；subscription_day = 每订阅月同一日 00:00 重置（没给订阅日就退回滚动 30 天）
    public static func planWindow(_ calls: [(t: TimeInterval, w: Double)], kind: String, seconds: Double, limit: Int, now: TimeInterval,
                                  timeZone: TimeZone = .current, subscribedDay: Int? = nil) -> QuotaWindow? {
        guard limit > 0 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let sorted = calls.filter { $0.t <= now }.sorted { $0.t < $1.t }
        var start: TimeInterval?, end: TimeInterval?
        switch kind {
        case "first_use":
            // 记账只留 31 天也不影响：任何 ≥ 窗口长度的空档之后那笔都会开新窗口，从那里起两条链一致。
            // ponytail: 连续 31 天每个窗口都有请求、从没停过时锚点推不出来（要持久保存锚点）；真人会睡觉，不做
            var s: TimeInterval?
            for c in sorted where s == nil || c.t >= s! + seconds { s = c.t }
            if let s, now < s + seconds { start = s; end = s + seconds }
            else { start = now; end = nil }                      // 上个窗口已过、还没新请求：窗口没开始
        case "monday":
            // 按日历算本地周一零点，不加固定秒数（跨夏令时那周不是 7×86400 秒）
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date(timeIntervalSince1970: now))
            comps.weekday = 2
            if var s = cal.date(from: comps) {
                if s.timeIntervalSince1970 > now, let prev = cal.date(byAdding: .weekOfYear, value: -1, to: s) { s = prev }
                start = s.timeIntervalSince1970
                end = cal.date(byAdding: .weekOfYear, value: 1, to: s)?.timeIntervalSince1970
            }
        case "subscription_day" where subscribedDay != nil:
            let day = subscribedDay!
            func anchor(_ monthOffset: Int) -> TimeInterval? {
                guard let base = cal.date(byAdding: .month, value: monthOffset, to: Date(timeIntervalSince1970: now)) else { return nil }
                var c = cal.dateComponents([.year, .month], from: base)
                c.day = min(day, cal.range(of: .day, in: .month, for: base)?.count ?? day)
                return cal.date(from: c)?.timeIntervalSince1970
            }
            if let this = anchor(0) {
                start = this <= now ? this : anchor(-1)
                end = this <= now ? anchor(1) : this
            }
        default: break
        }
        if let start {
            let used = sorted.filter { $0.t >= start && (end == nil || $0.t < end!) }.reduce(0) { $0 + $1.w }
            var w = QuotaWindow(usedPct: min(100, Int((used / Double(limit) * 100).rounded())), resetsAt: end, capturedAt: now,
                                windowSeconds: end.map { $0 - start } ?? seconds)
            w.isEstimate = true
            return w
        }
        // rolling（及缺订阅日的 subscription_day）
        let inWindow = sorted.filter { $0.t >= now - seconds }
        let used = inWindow.reduce(0) { $0 + $1.w }
        var w = QuotaWindow(usedPct: min(100, Int((used / Double(limit) * 100).rounded())), resetsAt: inWindow.first.map { $0.t + seconds },
                            capturedAt: now, windowSeconds: seconds)
        w.isRolling = true
        w.isEstimate = true
        if let first = inWindow.first { w.releaseCount = inWindow.filter { $0.t < first.t + 60 }.count }
        return w
    }

    static func windowLabel(_ key: String) -> String { key == "5h" ? "5h" : key == "weekly" ? L("周", "weekly") : L("月", "monthly") }

    /// 一个套餐按记账算出各窗口 + 独立模型池 + 口径说明
    static func estimatePlan(_ plan: PlanLimit, calls: [(t: TimeInterval, model: String)], now: TimeInterval)
        -> (windows: [String: QuotaWindow], pools: [SubQuota], note: String) {
        func pool(_ model: String) -> String? {
            plan.modelPools.keys.filter { model.lowercased().hasPrefix($0.lowercased()) }.max { $0.count < $1.count }
        }
        func windows(_ p: PlanLimit, _ cs: [(t: TimeInterval, model: String)]) -> [String: QuotaWindow] {
            var out: [String: QuotaWindow] = [:]
            for w in planWindows {
                guard let limit = p.limits[w.key] else { continue }
                out[w.key] = planWindow(cs.map { ($0.t, p.weight($0.model)) }, kind: p.resets[w.key] ?? "rolling", seconds: w.seconds,
                                        limit: limit, now: now, timeZone: p.timeZone, subscribedDay: p.subscribedDay)
            }
            return out
        }
        let shared = calls.filter { pool($0.model) == nil }
        var pools: [SubQuota] = []
        for (name, mp) in plan.modelPools.sorted(by: { $0.key < $1.key }) {
            let ws = windows(mp, calls.filter { pool($0.model) == name })
            // 每个模型池只挂最紧的那个窗口在卡片上（详情看 planLimitText）
            if let tight = ws.values.max(by: { $0.usedPct < $1.usedPct }) { pools.append(SubQuota(name: name, window: tight)) }
        }
        let in5h = shared.filter { $0.t >= now - 5 * 3600 }.count
        let basis = plan.weights.isEmpty ? L("每次请求记 1（模型系数未配置）", "1 per request (no model weights set)")
                                         : L("按模型系数折算", "weighted by model")
        let note = L("本机记账 5h 内 \(in5h) 次 · \(basis) · 真值以厂商控制台为准",
                     "\(in5h) logged in 5h · \(basis) · the provider console is authoritative")
        return (windows(plan, shared), pools, note)
    }

    func priceTable() -> PriceTable {
        let path = "\(home)/.config/vibegauge/prices.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return PriceTable() }
        let mtime = mod.timeIntervalSince1970
        if let c = priceCache, c.mtime == mtime { return c.table }
        let t = readJSON(path).map { PriceTable(json: $0) } ?? PriceTable()
        priceCache = (mtime, t)
        return t
    }

    func parseAPICallLine(_ line: Substring) -> APICall? {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ts = (j["epoch"] as? NSNumber)?.doubleValue ?? parseISO(j["ts"] as? String) ?? 0
        guard ts > 0, let host = j["host"] as? String else { return nil }
        func n(_ k: String) -> Int64 { Int64((j[k] as? NSNumber)?.intValue ?? 0) }
        return APICall(ts: ts, host: host, provider: j["provider"] as? String ?? host,
                       model: (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?",
                       ctx: n("ctx"), cacheRead: n("cache_read"), cacheWrite: n("cache_write"),
                       out: n("out"), think: n("think"),
                       status: (j["status"] as? NSNumber)?.intValue ?? 0,
                       ms: (j["ms"] as? NSNumber)?.intValue ?? 0,
                       key: j["key"] as? String ?? "",
                       rl: (j["rl"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
                       // 旧版代理没有 complete / sent：它记本地失败时带 error 字段、状态码 502
                       complete: (j["complete"] as? Bool) ?? !((j["status"] as? NSNumber)?.intValue == 502 && j["error"] != nil),
                       sent: (j["sent"] as? Bool) ?? !((j["status"] as? NSNumber)?.intValue == 502 && j["error"] != nil),
                       parsed: (j["parsed"] as? Bool) ?? true)
    }

    /// api-calls.jsonl 也是 append-only：同样的 offset 增量 + 指纹识别重写；
    /// 保留 31 天（Coding Plan 有"月"窗口要算；一条记录几十字节，18000 次/月也就一两 MB）
    func ingestAPICalls() {
        let path = ProxyManager.shared.callsPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else {
            apiCalls = []
            apiFile = FileParseState()
            return
        }
        let mtime = mod.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if apiFile.mtime == mtime && apiFile.size == size { return }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 256)) ?? Data()
        if size < apiFile.size || head != apiFile.head {
            apiFile = FileParseState()
            apiCalls = []
        }
        apiFile.head = head
        do { try fh.seek(toOffset: apiFile.parsedOffset) } catch { return }
        let data = fh.readDataToEndOfFile()
        if let lastNL = data.lastIndex(of: 0x0A) {
            let chunk = data[data.startIndex...lastNL]
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                if let c = parseAPICallLine(line) { apiCalls.append(c) }
            }
            apiFile.parsedOffset += UInt64(chunk.count)
        }
        apiFile.mtime = mtime
        apiFile.size = size
        let horizon = Date().timeIntervalSince1970 - 31 * 86400
        if let first = apiCalls.first, first.ts < horizon { apiCalls.removeAll { $0.ts < horizon } }
    }

    // MARK: 限流响应头 → 额度（代理被动记下来的，不为查额度多发一个请求）

    /// 把一组 `*ratelimit*` 响应头解析成「已用 % + 重置时刻」。
    /// 各家写法不一，统一按「去掉 limit/remaining/reset 这个词，剩下的算同一族」来配对：
    /// - Anthropic：`anthropic-ratelimit-requests-limit|-remaining|-reset`（reset 是 ISO8601）
    /// - OpenAI：`x-ratelimit-limit-requests|-remaining-requests|-reset-requests`（reset 是 "6m0s" 这种时长）
    /// - GitHub/通用：`x-ratelimit-limit|-remaining|-reset`（reset 是 epoch 秒；有的家给毫秒）
    /// 多族并存时取最紧的那族（剩得最少的），标签带上族名让用户知道是按什么限的。
    public static func parseRateLimitHeaders(_ headers: [String: String],
                                             now: TimeInterval = Date().timeIntervalSince1970)
        -> (usedPct: Int, resetsAt: TimeInterval?, label: String)? {
        var fams: [String: (limit: Double?, remaining: Double?, reset: String?)] = [:]
        for (rawKey, value) in headers {
            let key = rawKey.lowercased()
            guard key.contains("ratelimit") || key.contains("rate-limit") else { continue }
            var parts = key.split(separator: "-").map(String.init)
            guard let idx = parts.firstIndex(where: { ["limit", "remaining", "reset"].contains($0) }) else { continue }
            let kind = parts.remove(at: idx)
            let family = parts.joined(separator: "-")
            var f = fams[family] ?? (nil, nil, nil)
            switch kind {
            case "limit": f.limit = Double(value)
            case "remaining": f.remaining = Double(value)
            default: f.reset = value
            }
            fams[family] = f
        }

        var best: (usedPct: Int, resetsAt: TimeInterval?, label: String)? = nil
        for (family, f) in fams {
            guard let limit = f.limit, limit > 0, let remaining = f.remaining else { continue }
            let used = Int(((limit - remaining) / limit * 100).rounded())
            let reset = f.reset.flatMap { parseResetValue($0, now: now) }
            // 族名里去掉噪声词，剩下 requests/tokens 这类才有信息量
            let name = family.split(separator: "-").filter { !["x", "anthropic", "ratelimit", "rate", "openai"].contains($0) }
                .joined(separator: "-")
            let label = name.isEmpty ? L("限流", "rate limit") : name
            if best == nil || used > best!.usedPct { best = (max(0, min(100, used)), reset, label) }
        }
        return best
    }

    /// reset 字段三种写法：epoch 秒 / epoch 毫秒 / 相对时长（"6m0s"、"30s"、"1500ms"）/ ISO8601
    static func parseResetValue(_ raw: String, now: TimeInterval) -> TimeInterval? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if let iso = Fmt.parseISODate(v) { return iso }
        if let n = Double(v) {
            if n > 1_000_000_000_000 { return n / 1000 }     // 毫秒时间戳
            if n > 1_000_000_000 { return n }                // 秒时间戳
            return now + n                                   // 纯数字的相对秒数
        }
        // "6m0s" / "1h2m3s" / "500ms"
        guard let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|h|m|s)"#) else { return nil }
        let ns = v as NSString
        let ms = re.matches(in: v, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return nil }
        var secs = 0.0
        for m in ms {
            let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
            switch ns.substring(with: m.range(at: 2)) {
            case "ms": secs += n / 1000
            case "h": secs += n * 3600
            case "m": secs += n * 60
            default: secs += n
            }
        }
        return now + secs
    }

    // MARK: 记账覆盖体检（哪些 BASE_URL 没走代理）

    /// 从一行 shell 配置里抠出「变量名 + 上游主机」。**只取这两样**：同一行常常跟着 API key，
    /// 我们既不解析也不保存它。返回 nil = 这行没有 BASE_URL。
    public static func parseBaseURLLine(_ raw: String, proxyPrefix: String) -> (name: String, host: String, proxied: Bool)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#") else { return nil }
        // URL 取到第一个引号/空白/反斜杠为止：zsh 里这些行常以续行符 \ 结尾
        guard let re = try? NSRegularExpression(pattern: #"([A-Z0-9_]*(?:BASE_URL|API_BASE|BASE_URI))\s*=\s*["']?([^"'\s\\]+)"#) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1))
        var url = ns.substring(with: m.range(at: 2))
        let proxied = url.hasPrefix(proxyPrefix)
        if proxied { url = String(url.dropFirst(proxyPrefix.count)) }
        // 取主机：可能是 https://host/path，也可能被代理前缀包成 http://127.0.0.1:18790/https://host/path
        let authority = url
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .split(separator: "/").first.map(String.init) ?? url
        // https://user:password@host → 只要 host，账号密码不进面板
        let host = authority.split(separator: "@").last.map(String.init) ?? authority
        guard !host.isEmpty, host.contains(".") || host.contains(":") else { return nil }
        return (name, host, proxied)
    }

    /// 扫 shell 配置。只读用户自己的 rc 文件，60s 节流。
    public func scanProxyCoverage() -> ProxyCoverage {
        let now = Date().timeIntervalSince1970
        if let c = coverageCache, now - c.at < 60 { return c.cov }
        let prefix = ProxyManager.shared.prefix
        var cov = ProxyCoverage()
        for f in [".zshrc", ".zshenv", ".bashrc", ".bash_profile", ".profile"] {
            let path = "\(home)/\(f)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                guard let e = Self.parseBaseURLLine(line, proxyPrefix: prefix) else { continue }
                cov.entries.append(ProxyCoverage.Entry(name: e.name, host: e.host, file: f, line: i + 1, proxied: e.proxied))
            }
        }
        coverageCache = (now, cov)
        return cov
    }

    func balanceText(_ d: [String: Any]) -> String {
        let cur = (d["currency"] as? String ?? "").uppercased()
        let sym = cur == "CNY" ? "¥" : (cur == "USD" ? "$" : (cur.isEmpty ? "" : cur + " "))
        if let b = (d["balance"] as? NSNumber)?.doubleValue { return String(format: L("余额 %@%.2f", "%@%.2f balance"), sym, b) }
        if let u = (d["usage"] as? NSNumber)?.doubleValue {
            if let l = (d["limit"] as? NSNumber)?.doubleValue { return String(format: L("已用 %@%.2f / %@%.2f", "%@%.2f / %@%.2f used"), sym, u, sym, l) }
            return String(format: L("已用 %@%.2f", "%@%.2f used"), sym, u)
        }
        return ""
    }

    /// 同一上游路由（host + provider）下出现过几个不同 key：超过一个就按账户拆卡，
    /// 否则合计用量会配上其中一个账户的余额 / 套餐。
    static func splitGroups(_ calls: [APICall]) -> Set<String> {
        var keys: [String: Set<String>] = [:]
        for c in calls where !c.key.isEmpty { keys["\(c.host)|\(c.provider)", default: []].insert(c.key) }
        return Set(keys.filter { $0.value.count > 1 }.keys)
    }
    /// 卡片 ID 总带完整指纹：拆不拆卡只影响标题，不影响身份（采样、通知键、详情页都跟着 ID 走）
    static func cardID(host: String, provider: String, key: String) -> String {
        "\(host)|\(provider)#" + (key.isEmpty ? "-" : key)
    }

    public func scanAPI() -> ProxyStatus {
        lock.lock(); defer { lock.unlock() }
        let pm = ProxyManager.shared
        var st = ProxyStatus()
        st.installed = pm.isInstalled
        st.port = pm.port
        let now = Date().timeIntervalSince1970
        if let h = healthCache, now - h.at < 5 {
            st.running = h.running
            st.callsSinceStart = h.calls
        } else {
            let h = pm.health()
            healthCache = (now, h != nil, h?.calls ?? 0)
            st.running = h != nil
            st.callsSinceStart = h?.calls ?? 0
        }

        ingestAPICalls()
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let prices = priceTable()
        // byHost 的键是卡片 ID（见 cardID），不再只是 host
        var byHost: [String: APIProviderStatus] = [:]
        var latency: [String: [Int]] = [:]              // 卡片 → 今日各次耗时（算 p50/p95）
        var byKey: [String: [String: APIKeyUsage]] = [:]  // 卡片 → 指纹 → 用量
        let split = Self.splitGroups(apiCalls)
        func card(_ c: APICall) -> String { Self.cardID(host: c.host, provider: c.provider, key: c.key) }
        func newCard(_ id: String, host: String, provider: String, key: String) -> APIProviderStatus {
            var p = APIProviderStatus(host: host, provider: provider)
            p.cardID = id
            p.account = key.isEmpty ? "-" : key
            p.showsAccount = split.contains("\(host)|\(provider)")
            return p
        }

        for c in apiCalls where c.ts >= startOfToday {
            let id = card(c)
            var p = byHost[id] ?? newCard(id, host: c.host, provider: c.provider, key: c.key)
            p.calls += 1
            if c.failed { p.errors += 1 }
            if c.status == 429 { p.count429 += 1 }
            if !c.parsed && !c.failed { p.unknownUsage += 1 }   // 调用成功但没拿到用量（如客户端没开 include_usage）
            p.ctx += c.ctx
            p.cacheRead += c.cacheRead
            p.out += c.out
            p.think += c.think
            p.lastTS = max(p.lastTS, c.ts)
            if !p.models.contains(c.model) { p.models.append(c.model) }

            let cost = prices.cost(model: c.model, ctx: c.ctx, cacheRead: c.cacheRead, cacheWrite: c.cacheWrite, out: c.out)
            if let cost = cost { p.cost = (p.cost ?? 0) + cost }
            byHost[id] = p

            if c.ms > 0 { latency[id, default: []].append(c.ms) }

            let fp = c.key.isEmpty ? L("无 key", "no key") : c.key
            var k = byKey[id]?[fp] ?? APIKeyUsage(fingerprint: fp)
            k.calls += 1
            if c.failed { k.errors += 1 }
            k.ctx += c.ctx
            k.out += c.out
            k.lastTS = max(k.lastTS, c.ts)
            if let cost = cost { k.cost = (k.cost ?? 0) + cost }
            if !k.models.contains(c.model) { k.models.append(c.model) }
            byKey[id, default: [:]][fp] = k
        }

        // 限流头：只认该卡最近一条带头的调用（旧的没参考价值；限流按 key 算，别串到别的账户）
        var lastRL: [String: (t: TimeInterval, rl: [String: String])] = [:]
        for c in apiCalls where !c.rl.isEmpty {
            let id = card(c)
            if c.ts > (lastRL[id]?.t ?? 0) { lastRL[id] = (c.ts, c.rl) }
        }
        for (host, v) in lastRL {
            guard now - v.t < 3600,                              // 一小时前的余量早就变了
                  // 「6m 后重置」是相对那次响应说的，基准必须是记录时间，按扫描时间算重置点会一直往后推
                  let q = Self.parseRateLimitHeaders(v.rl, now: v.t) else { continue }
            byHost[host]?.headerWindow = QuotaWindow(usedPct: q.usedPct, resetsAt: q.resetsAt, capturedAt: v.t)
            byHost[host]?.headerLabel = q.label
        }

        for (host, ms) in latency {
            byHost[host]?.p50ms = Fmt.percentile(ms, 0.50)
            byHost[host]?.p95ms = Fmt.percentile(ms, 0.95)
            byHost[host]?.maxms = ms.max() ?? 0
        }
        for (host, keys) in byKey {
            byHost[host]?.keys = keys.values.sorted { $0.calls > $1.calls }
            byHost[host]?.costCurrency = prices.currency
        }

        // 订阅制 Coding Plan：厂商不给用量接口 → 按本机记账的请求数估。滚动窗口，标明是估算。
        let plans = planLimits()
        if !plans.isEmpty {
            var stamps: [String: [(t: TimeInterval, model: String)]] = [:]       // 卡片 → 各次调用（31 天内）
            for c in apiCalls where c.sent { stamps[card(c), default: []].append((c.ts, c.model)) }
            for (key, plan) in plans {
                // 今天还没调用，但周 / 月窗口里还有用量：过了零点卡片不能消失
                for c in apiCalls where (c.provider == key || c.host == key) && byHost[card(c)] == nil {
                    byHost[card(c)] = newCard(card(c), host: c.host, provider: c.provider, key: c.key)
                }
                // 拆了账户就每个账户各按自己的请求数估：每个账户各有一份套餐上限
                for host in byHost.keys where byHost[host]!.provider == key || byHost[host]!.host == key {
                guard let calls = stamps[host] else { continue }
                byHost[host]?.plan = plan.label
                byHost[host]?.isSubscription = true
                byHost[host]?.quotaIsEstimate = true
                let est = Self.estimatePlan(plan, calls: calls, now: now)
                byHost[host]?.fiveHour = est.windows["5h"]
                byHost[host]?.sevenDay = est.windows["weekly"]
                byHost[host]?.monthly = est.windows["monthly"]
                byHost[host]?.subQuotas = est.pools
                byHost[host]?.estimateNote = est.note
                byHost[host]?.planLimitText = plan.limits.isEmpty ? "" : Self.planWindows.compactMap { w in
                    plan.limits[w.key].map { "\(Self.windowLabel(w.key)) \($0)" } }.joined(separator: " · ") + L(" 次", " requests")
                }
            }
        }
        if let q = readJSON(pm.quotaPath) {
            for (entry, v) in q {
                guard let d = v as? [String: Any] else { continue }
                // 新版代理按「host#指纹」分账户写，按账户精确对上卡片；旧版只写 host：
                // 这个 host 只出现过一个 key 才认得出是谁的，否则不认
                let parts = entry.split(separator: "#", maxSplits: 1).map(String.init)
                let host = parts[0]
                let provider = d["provider"] as? String ?? host
                var fp = parts.count > 1 ? parts[1] : ""
                if fp.isEmpty {
                    let keys = Set(apiCalls.filter { $0.host == host && !$0.key.isEmpty }.map(\.key))
                    guard keys.count <= 1 else { continue }
                    fp = keys.first ?? ""
                }
                let account = fp.isEmpty ? "-" : fp
                // 同一 host、同一账户可能有多条路由（火山 Coding / 按量同 key）：优先 provider 名一致的那张
                let candidates = byHost.values.filter { $0.host == host && $0.account == account }
                let id = (candidates.first { $0.provider == provider } ?? candidates.first)?.id ?? Self.cardID(host: host, provider: provider, key: fp)
                var p = byHost[id] ?? newCard(id, host: host, provider: provider, key: fp)
                let cap = (d["captured_at"] as? NSNumber)?.doubleValue
                if let e = d["error"] as? String { p.quotaError = e }
                let kind = d["kind"] as? String ?? ""
                // 探针报错（临时网络问题等）：只记错误，不清掉 plans.json 给的套餐身份和估算
                if kind == "quota", d["error"] == nil {
                    if let plan = d["plan"] as? String, !plan.isEmpty { p.plan = plan; p.isSubscription = true }
                    let wins = d["windows"] as? [String: Any] ?? [:]
                    func win(_ k: String) -> QuotaWindow? {
                        guard let w = wins[k] as? [String: Any], let used = clampPct(w["used_pct"] as? NSNumber) else { return nil }
                        return QuotaWindow(usedPct: used, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue, capturedAt: cap,
                                           windowSeconds: k == "5h" ? 5 * 3600 : 7 * 86400)
                    }
                    if let w = win("5h") { p.fiveHour = w }
                    if let w = win("weekly") { p.sevenDay = w }
                } else if kind == "balance" {
                    p.balanceText = balanceText(d)
                }
                byHost[id] = p
            }
        }
        st.coverage = scanProxyCoverage()
        st.hasPriceTable = !prices.isEmpty
        st.priceAsOf = prices.asOf
        st.providers = byHost.values.sorted { $0.lastTS > $1.lastTS }.map { p in
            var p = p       // API 上游的额度也记采样，火山这种估算窗口同样能给"当前节奏"
            if p.fiveHour != nil { sampleAndFill(&p.fiveHour!, key: "api|\(p.id)|5h", now: now) }
            if p.sevenDay != nil { sampleAndFill(&p.sevenDay!, key: "api|\(p.id)|w", now: now) }
            return p
        }
        saveSamplesIfDue(now)
        return st
    }
}
