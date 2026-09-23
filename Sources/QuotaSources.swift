import Foundation

// 额度来源适配器：Claude / Codex（含远程）/ Grok / Gemini(agy) 各自的额度与档位读取
extension ProcessScanner {
    // MARK: 档位（只报数据里真实有的，查不到就说查不到，不猜）

    func getClaudeTier() -> String {
        if let oa = readJSON("\(home)/.claude.json")?["oauthAccount"] as? [String: Any] {
            let rate = (oa["organizationRateLimitTier"] as? String ?? "").lowercased()   // e.g. default_claude_max_5x
            if rate.contains("max_20x") { return "Max 20x" }
            if rate.contains("max_5x") { return "Max 5x" }
            if rate.contains("max") { return "Max" }
            if rate.contains("enterprise") { return "Enterprise" }
            if rate.contains("team") { return "Team" }
            if rate.contains("pro") { return "Pro" }
            let orgType = (oa["organizationType"] as? String ?? "").lowercased()          // e.g. claude_max
            if orgType.contains("max") { return "Max" }
            if orgType.contains("pro") { return "Pro" }
            if (oa["billingType"] as? String ?? "").contains("subscription") { return L("订阅", "Subscription") }
            return L("已登录", "Signed in")
        }
        if env["ANTHROPIC_API_KEY"] != nil { return "API Key" }
        return L("未登录", "Not signed in")
    }

    /// OpenAI JWT 里的 chatgpt_plan_type → 展示名。没有 "5x" 这种档位，那是 Claude 的叫法。
    public static func codexPlanLabel(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "go": return "Go"
        case "team", "business": return "Team"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        case "": return ""
        default: return plan.prefix(1).uppercased() + plan.dropFirst()
        }
    }

    /// 套餐优先取会话日志里的 plan_type（不碰认证文件）；近两天没会话时才看 auth.json 的 id_token 声明兜底
    func getCodexTier(sessionPlan: String) -> String {
        if !sessionPlan.isEmpty { return ProcessScanner.codexPlanLabel(sessionPlan) }
        if let auth = readJSON("\(home)/.codex/auth.json") {
            if let idTok = (auth["tokens"] as? [String: Any])?["id_token"] as? String {
                let segs = idTok.split(separator: ".")
                if segs.count >= 2 {
                    var payload = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    let rem = payload.count % 4
                    if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
                    if let d = Data(base64Encoded: payload),
                       let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let plan = (p["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String,
                       !plan.isEmpty {
                        return ProcessScanner.codexPlanLabel(plan)
                    }
                }
            }
            let mode = auth["auth_mode"] as? String ?? ""
            if mode == "chatgpt" { return L("ChatGPT 登录", "ChatGPT sign-in") }
            if mode == "api_key" || auth["OPENAI_API_KEY"] != nil { return "API Key" }
        }
        if env["OPENAI_API_KEY"] != nil { return "API Key" }
        return L("未登录", "Not signed in")
    }

    /// Antigravity 本地没有套餐字段；新版 agy 连 token 文件都不落盘了 → 能拉到额度就是登录态
    func getGeminiTier(hasQuota: Bool) -> String {
        if let tok = readJSON("\(home)/.gemini/antigravity-cli/antigravity-oauth-token") {
            let method = (tok["auth_method"] as? String ?? "").lowercased()
            return method == "consumer" ? L("个人 OAuth", "Personal OAuth") : "OAuth"
        }
        if hasQuota { return L("已登录", "Signed in") }
        if env["GEMINI_API_KEY"] != nil { return "API Key" }
        return L("未登录", "Not signed in")
    }

    /// 直接用 grok 自己缓存的 subscription_tier_display（形如 "X Premium+" / "SuperGrok"），原样显示不改写
    func getGrokTier() -> String {
        if let cache = readJSON("\(home)/.grok/settings_cache.json"),
           let payloadStr = cache["payload"] as? String,
           let pData = payloadStr.data(using: .utf8),
           let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let settings = pJson["settings"] as? [String: Any] {
            if let display = settings["subscription_tier_display"] as? String, !display.isEmpty { return display }
            if let tier = settings["subscription_tier"] as? String, !tier.isEmpty { return tier }
        }
        if let auth = readJSON("\(home)/.grok/auth.json") {
            for v in auth.values {
                if let d = v as? [String: Any], d["auth_mode"] as? String == "oidc" { return L("已登录", "Signed in") }
            }
        }
        if env["XAI_API_KEY"] != nil || env["GROK_API_KEY"] != nil { return "API Key" }
        return L("未登录", "Not signed in")
    }

    // MARK: 额度（全部带 resets_at + 采集时间）

    /// Claude：状态栏截获的 rate_limits（Claude Code 下发的整个对象）+ _captured_at。
    /// 两个来源取较新的：VibeGauge 自带桥接写 ~/.config/vibegauge/claude-usage.json；自己配过 tee 的写 ~/.claude/claude-usage.json。
    /// 目前只有 five_hour / seven_day；若将来出现按模型的窗口键（如 seven_day_fable），自动当副池显示，键名即池名。
    func readClaudeQuota() -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?, extraName: String, extra5h: QuotaWindow?, extraW: QuotaWindow?) {
        // 采集时间：优先 _captured_at；别人家的 tee 没写这个字段就用文件修改时间，免得永远输给另一个来源
        let sources = ["\(home)/.config/vibegauge/claude-usage.json", "\(home)/.claude/claude-usage.json"].compactMap { path -> (json: [String: Any], at: Double)? in
            guard let json = readJSON(path) else { return nil }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (json, (json["_captured_at"] as? NSNumber)?.doubleValue ?? mtime)
        }
        guard let newest = sources.max(by: { $0.at < $1.at }) else { return (nil, nil, "", nil, nil) }
        let json = newest.json
        let captured: Double? = newest.at
        func win(_ d: Any?, _ windowSeconds: Double) -> QuotaWindow? {
            guard let d = d as? [String: Any], let used = clampPct(d["used_percentage"] as? NSNumber) else { return nil }
            return QuotaWindow(usedPct: used, resetsAt: (d["resets_at"] as? NSNumber)?.doubleValue,
                               capturedAt: captured, windowSeconds: windowSeconds)
        }
        var extraName = ""
        var extra5h: QuotaWindow? = nil
        var extraW: QuotaWindow? = nil
        // 只认 five_hour_* / seven_day_* 前缀；目前只展示一个副池，按键名排序取第一个（结果不随字典遍历顺序变）
        for k in json.keys.sorted() where (k.hasPrefix("five_hour_") || k.hasPrefix("seven_day_")) {
            let v = json[k]
            guard let w = win(v, k.hasPrefix("five_hour") ? 5 * 3600 : 7 * 86400) else { continue }
            let base = k.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "five_hour_", with: "")
            let name = base.prefix(1).uppercased() + base.dropFirst()
            guard extraName.isEmpty || extraName == name else { continue }   // 只展示一个副池
            extraName = name
            if k.hasPrefix("five_hour") { extra5h = w } else { extraW = w }
        }
        return (win(json["five_hour"], 5 * 3600), win(json["seven_day"], 7 * 86400), extraName, extra5h, extraW)
    }

    // MARK: Codex 额度（按 limit_id 分桶：主桶 "codex"，新版 CLI 另报如 codex_bengalfox/Spark；本机 + 远程合并取最新）

    struct CodexBucket {
        var id: String            // limit_id；旧版 CLI 不带 → 视为 "codex"
        var name: String          // limit_name，如 "GPT-5.3-Codex-Spark"
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var plan: String
        var captured: TimeInterval
    }
    /// 额度打满：请求被拒时 Codex 写 rate_limits 但百分比全为 null，真信号在 task_complete 的
    /// error.codex_error_info == "usage_limit_exceeded"，重置时刻在 error.message 文案里。
    struct CodexLimitHit {
        var at: TimeInterval
        var resetsAt: TimeInterval?
    }
    struct CodexParse {
        var buckets: [String: CodexBucket] = [:]
        var limitHit: CodexLimitHit? = nil
    }

    /// 另一台真正跑 Codex 的机器（默认空 = 关闭远程合并）。
    /// 开启：`defaults write com.haifeng.vibegauge codexRemoteHost <ssh-host>`，该 host 需能免密 ssh。
    public var codexRemoteHost: String {
        let raw = (UserDefaults.standard.string(forKey: "codexRemoteHost") ?? "").trimmingCharacters(in: .whitespaces)
        return Self.isValidSSHHost(raw) ? raw : ""
    }

    /// 这个值会被拼进 `ssh <host> '...'` 的 shell 命令，所以只放行合法主机名/别名/user@host。
    /// 虽然只有本机用户能写这个 UserDefaults，但拼 shell 就该校验 —— 别给分号和反引号留门。
    public static func isValidSSHHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 255 else { return false }
        return h.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?$"#, options: .regularExpression) != nil
    }

    public func codexRemoteStatus() -> (host: String, ok: Bool, ageSeconds: Int) {
        remoteLock.lock(); defer { remoteLock.unlock() }
        return (codexRemoteHost, remoteCodex.ok, Int(Date().timeIntervalSince1970 - remoteCodex.at))
    }

    func findRateLimits(_ x: Any) -> [String: Any]? {
        guard let d = x as? [String: Any] else { return nil }
        if d["primary"] != nil { return d }
        for v in d.values { if let r = findRateLimits(v) { return r } }
        return nil
    }

    /// 每个 limit_id 取采集时间最新的一条，并抓最新的"额度耗尽"事件。
    /// 不能靠行序：远程输出是多文件拼接、顺序随机；半行/坏行直接跳过。
    func parseCodexText(_ text: String, fallbackTime: TimeInterval) -> CodexParse {
        var out = CodexParse()
        for l in text.components(separatedBy: "\n") {
            let hasPct = l.contains("used_percent")
            let hasHit = l.contains("usage_limit_exceeded")
            guard hasPct || hasHit,
                  let data = l.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = parseISO(json["timestamp"] as? String) ?? fallbackTime

            if hasHit, let msg = findErrorMessage(json) {
                if ts > (out.limitHit?.at ?? -1) {
                    out.limitHit = CodexLimitHit(at: ts, resetsAt: Fmt.parseUsageLimitReset(msg))
                }
            }

            guard hasPct, let rl = findRateLimits(json) else { continue }
            let rawId = rl["limit_id"] as? String ?? ""
            let id = rawId.isEmpty ? "codex" : rawId
            if ts <= (out.buckets[id]?.captured ?? -1) { continue }
            var b = CodexBucket(id: id, name: rl["limit_name"] as? String ?? "", fiveHour: nil, weekly: nil,
                                plan: rl["plan_type"] as? String ?? "", captured: ts)
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let used = clampPct(w["used_percent"] as? NSNumber) else { continue }
                let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                let win = QuotaWindow(usedPct: used, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue, capturedAt: ts,
                                      windowSeconds: mins > 0 ? Double(mins) * 60 : (mins >= 1440 ? 7 * 86400 : 5 * 3600))
                if mins >= 1440 { b.weekly = win } else { b.fiveHour = win }
            }
            // 百分比全 null（请求被拒时就是这样）→ 不是有效快照，别覆盖旧的真值
            if b.fiveHour != nil || b.weekly != nil { out.buckets[id] = b }
        }
        return out
    }

    func findErrorMessage(_ x: Any) -> String? {
        guard let d = x as? [String: Any] else { return nil }
        if let e = d["error"] as? [String: Any] {
            if (e["codex_error_info"] as? String) == "usage_limit_exceeded", let m = e["message"] as? String { return m }
        }
        for v in d.values { if let r = findErrorMessage(v) { return r } }
        return nil
    }

    func mergeNewest(_ into: inout CodexParse, _ src: CodexParse) {
        for (id, b) in src.buckets where b.captured > (into.buckets[id]?.captured ?? -1) { into.buckets[id] = b }
        if let h = src.limitHit, h.at > (into.limitHit?.at ?? -1) { into.limitHit = h }
    }

    /// ~/.codex/sessions 下 window 秒内改过的会话文件（修改时间每次实时读）。
    /// 按修改时间找、不按目录日期：`codex resume` 的旧会话会继续写进它创建那天的目录，只看最近几天的目录就漏了。
    /// 候选集（7 天内改过的）60 秒刷新一次 —— 目录里常有上千个文件，不能每 8 秒全量遍历。
    func codexSessionFiles(modifiedWithin window: TimeInterval) -> [(path: String, mtime: TimeInterval)] {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        if now - codexCandidates.at >= 60 {
            var paths: [String] = []
            let root = URL(fileURLWithPath: "\(home)/.codex/sessions")
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       now - d.timeIntervalSince1970 < 7 * 86400 { paths.append(url.path) }
                }
            }
            codexCandidates = (now, paths)
        }
        return codexCandidates.paths.compactMap { path in
            guard let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now - d.timeIntervalSince1970 < window else { return nil }
            return (path, d.timeIntervalSince1970)
        }
    }

    /// 本机：48h 内改过的会话文件，各取每桶最新；单文件按 mtime 缓存
    func readLocalCodex() -> CodexParse {
        let files = codexSessionFiles(modifiedWithin: 48 * 3600)
        var merged = CodexParse()
        var seen = Set<String>()
        for f in files {
            seen.insert(f.path)
            let parsed: CodexParse
            if let c = codexFileCache[f.path], c.mtime == f.mtime {
                parsed = c.parsed
            } else {
                // 额度行每个请求都写一次，正常在末尾 256 KB 里；没有就逐级往前多读，32 MB 封顶 ——
                // 那么久没写过额度的会话早就不活跃了，别的文件里有更新的值。绝不整个读进内存。
                var window = 256 * 1024
                var tail = readTail(f.path, maxBytes: window)
                var pr = parseCodexText(tail, fallbackTime: f.mtime)
                while pr.buckets.isEmpty, pr.limitHit == nil, tail.utf8.count >= window, window < 32 << 20 {
                    window = min(window * 4, 32 << 20)
                    tail = readTail(f.path, maxBytes: window)
                    pr = parseCodexText(tail, fallbackTime: f.mtime)
                }
                parsed = pr
                codexFileCache[f.path] = (f.mtime, pr)
            }
            mergeNewest(&merged, parsed)
        }
        codexFileCache = codexFileCache.filter { seen.contains($0.key) }
        return merged
    }

    /// 远程主机（`codexRemoteHost`，默认关闭）：ssh 拉 48h 内会话文件各自最后一条额度行。
    /// 60s 节流；失败保留上次结果；不持扫描锁。
    public func refreshRemoteCodexIfDue(force: Bool = false) {
        let host = codexRemoteHost
        guard !host.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        remoteLock.lock()
        let due = force || now - remoteCodex.at >= 60
        remoteLock.unlock()
        guard due else { return }
        // 每个文件取：最后一条含百分比的行 + 最后一条额度耗尽事件
        let script = #"for f in $(find ~/.codex/sessions -name "*.jsonl" -mmin -2880 2>/dev/null); do tail -c 262144 "$f" | grep used_percent | tail -1; tail -c 262144 "$f" | grep usage_limit_exceeded | tail -1; done; echo __OK__"#
        let out = execute("ssh -o BatchMode=yes -o ConnectTimeout=4 -o ServerAliveInterval=5 -- \(host) '\(script)' 2>/dev/null")
        let ok = out.contains("__OK__")
        let parsed = ok ? parseCodexText(out, fallbackTime: now) : CodexParse()
        remoteLock.lock()
        remoteCodex = ok ? (now, true, parsed) : (now, false, remoteCodex.parsed)
        remoteLock.unlock()
        log.notice("remote codex \(host) ok=\(ok) buckets=\(parsed.buckets.count) limitHit=\(parsed.limitHit != nil)")
    }

    struct CodexSnapshot {
        var primary: CodexBucket?
        var plan: String
        var remoteOK: Bool
    }

    /// 只展示主桶 "codex"；其他桶（如 codex_bengalfox / Spark）解析出来只为了不被误当主桶，不显示
    func codexSnapshot() -> CodexSnapshot {
        var merged = readLocalCodex()
        remoteLock.lock()
        let remote = remoteCodex
        remoteLock.unlock()
        mergeNewest(&merged, remote.parsed)
        let plan = merged.buckets.values.sorted { $0.captured > $1.captured }.first { !$0.plan.isEmpty }?.plan ?? ""
        var primary = merged.buckets["codex"]

        // 额度耗尽事件比最后一个百分比快照更新 → 真值就是 100%，重置时刻取错误文案里的时间
        if let hit = merged.limitHit, hit.at > (primary?.weekly?.capturedAt ?? -1) {
            let now = Date().timeIntervalSince1970
            let stillHit = (hit.resetsAt ?? .greatestFiniteMagnitude) > now
            if stillHit {
                let win = QuotaWindow(usedPct: 100, resetsAt: hit.resetsAt ?? primary?.weekly?.resetsAt, capturedAt: hit.at,
                                      windowSeconds: 7 * 86400)
                if primary == nil {
                    primary = CodexBucket(id: "codex", name: "", fiveHour: nil, weekly: win, plan: plan, captured: hit.at)
                } else {
                    primary?.weekly = win
                    primary?.captured = hit.at
                }
            }
        }
        return CodexSnapshot(primary: primary, plan: plan, remoteOK: remote.ok)
    }

    /// Grok：grok CLI 自己在 ~/.grok/logs/unified.jsonl 记 "billing: fetched credits config"
    /// （creditUsagePercent = 周额度已用 %，currentPeriod.end = 重置点，subscriptionTier）。文件按 mtime+size 缓存。
    func readGrokQuota() -> (weekly: QuotaWindow?, tier: String) {
        let path = "\(home)/.grok/logs/unified.jsonl"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return (nil, "") }
        let mtime = mod.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if let c = grokQuotaCache, c.mtime == mtime, c.size == size { return (c.weekly, c.tier) }

        var weekly: QuotaWindow? = nil
        var tier = ""
        outer: for maxBytes in [512 * 1024, Int.max] {
            let text = readTail(path, maxBytes: maxBytes)
            for l in text.components(separatedBy: "\n").reversed() where l.contains("fetched credits config") {
                guard let data = l.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ctx = json["ctx"] as? [String: Any],
                      let cfg = ctx["config"] as? [String: Any],
                      let pct = clampPct(cfg["creditUsagePercent"] as? NSNumber) else { continue }
                let period = cfg["currentPeriod"] as? [String: Any]
                let pStart = parseISO(period?["start"] as? String)
                let pEnd = parseISO(period?["end"] as? String)
                // 周期长度用它自己给的起止算；给不出就不推算（windowSeconds 留 0）
                weekly = QuotaWindow(usedPct: pct, resetsAt: pEnd, capturedAt: parseISO(json["ts"] as? String),
                                     windowSeconds: (pStart != nil && pEnd != nil) ? max(0, pEnd! - pStart!) : 0)
                tier = ctx["subscriptionTier"] as? String ?? ""
                break outer
            }
            if text.utf8.count < maxBytes { break }
        }
        grokQuotaCache = (mtime, size, weekly, tier)
        return (weekly, tier)
    }

    /// Gemini（Antigravity）：两个池 gemini / 3p，各有 5h 与周窗口。
    /// 两个来源同一格式，逐个窗口取记录较新的：VibeGauge 自带桥接写 ~/.config/vibegauge/agy-quota.json；
    /// 装了 agy-hud 的写 ~/.cache/agy-hud/quota_cache.json（它会删掉已过期的窗口，桥接不删，过期由这里当 0%）。
    func readGeminiQuota() -> (native5h: QuotaWindow?, nativeW: QuotaWindow?, tp5h: QuotaWindow?, tpW: QuotaWindow?) {
        let files = ["\(home)/.config/vibegauge/agy-quota.json", "\(home)/.cache/agy-hud/quota_cache.json"].compactMap { readJSON($0) }
        func win(_ poolName: String, _ key: String) -> QuotaWindow? {
            files.compactMap { json -> QuotaWindow? in
                guard let pools = json["pools"] as? [String: Any], let p = pools[poolName] as? [String: Any],
                      let w = p[key] as? [String: Any], let rf = (w["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
                return QuotaWindow(
                    usedPct: max(0, min(100, Int(round((1.0 - rf) * 100.0)))),
                    resetsAt: (w["reset_at"] as? NSNumber)?.doubleValue,
                    capturedAt: (w["recorded_at"] as? NSNumber)?.doubleValue ?? (json["updated_at"] as? NSNumber)?.doubleValue,
                    windowSeconds: key == "5h" ? 5 * 3600 : 7 * 86400
                )
            }.max { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        }
        return (win("gemini", "5h"), win("gemini", "weekly"), win("3p", "5h"), win("3p", "weekly"))
    }
}
