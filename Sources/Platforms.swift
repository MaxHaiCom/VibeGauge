import Foundation

// 平台汇聚：把进程表、额度、用量拼成每个 AI 工具的一张卡
extension ProcessScanner {
    // MARK: 平台汇聚

    func sessionInfos(_ c: SessionCounts, _ kind: CLIKind) -> [SessionInfo] {
        let pids = (c.pids[kind] ?? []).sorted()
        guard !pids.isEmpty else { return [] }
        let key = "\(kind)"
        let now = Date().timeIntervalSince1970
        if let cached = sessionCache[key], cached.pids == pids, now - cached.at < 10 {
            return cached.infos
        }
        let cw = cwds(of: pids)
        let ag = ages(of: pids)
        let infos = pids.map { SessionInfo(pid: $0, cwd: cw[$0] ?? "?", startedAgo: ag[$0] ?? 0, memMB: c.mem[$0] ?? 0) }
            .sorted { $0.startedAgo > $1.startedAgo }
        sessionCache[key] = (now, pids, infos)
        return infos
    }

    func claudeDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.claude.json", "~/.config/vibegauge/claude-usage.json", "~/.claude/projects/*.jsonl"]
        if let oa = readJSON("\(home)/.claude.json")?["oauthAccount"] as? [String: Any] {
            if let v = oa["organizationRateLimitTier"] as? String { d.rows.append((L("限速档位字段", "Rate-limit tier field"), v)) }
            if let v = oa["organizationType"] as? String { d.rows.append((L("组织类型", "Organization type"), v)) }
            if let v = oa["billingType"] as? String { d.rows.append((L("计费方式", "Billing type"), v)) }
            if let v = oa["organizationRole"] as? String { d.rows.append((L("角色", "Role"), v)) }
            if let b = oa["hasExtraUsageEnabled"] as? Bool { d.rows.append((L("额外用量", "Extra usage"), b ? L("已开启", "Enabled") : L("未开启", "Disabled"))) }
            if let v = oa["subscriptionCreatedAt"] as? String, let t = Fmt.parseISODate(v) {
                d.rows.append((L("订阅开始", "Subscription started"), L("\(Fmt.dateText(t))（\(Int((Date().timeIntervalSince1970 - t) / 86400)) 天前）", "\(Fmt.dateText(t)) (\(Int((Date().timeIntervalSince1970 - t) / 86400))d ago)")))
            }
        }
        d.sessions = sessionInfos(c, .claude)
        return d
    }

    func codexDetail(_ c: SessionCounts, snapshot: CodexSnapshot, buckets: [String: CodexBucket]) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.codex/auth.json", "~/.codex/sessions/*/*.jsonl"]
        if let auth = readJSON("\(home)/.codex/auth.json"),
           let idTok = (auth["tokens"] as? [String: Any])?["id_token"] as? String {
            let segs = idTok.split(separator: ".")
            if segs.count >= 2 {
                var payload = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                let rem = payload.count % 4
                if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
                if let data = Data(base64Encoded: payload),
                   let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let a = p["https://api.openai.com/auth"] as? [String: Any] {
                    if let v = a["chatgpt_plan_type"] as? String { d.rows.append((L("套餐字段", "Plan field"), v)) }
                    if let v = a["chatgpt_subscription_active_until"] as? String, let t = Fmt.parseISODate(v) {
                        let left = Int((t - Date().timeIntervalSince1970) / 86400)
                        d.rows.append((L("订阅有效期至", "Subscription active until"), L("\(Fmt.dateText(t))（还剩 \(left) 天）", "\(Fmt.dateText(t)) (\(left)d left)")))
                    }
                }
            }
            if let mode = auth["auth_mode"] as? String { d.rows.append((L("鉴权方式", "Auth method"), mode)) }
        }
        if !codexRemoteHost.isEmpty {
            remoteLock.lock(); let ok = remoteCodex.ok; let at = remoteCodex.at; remoteLock.unlock()
            d.rows.append((L("远程合并主机", "Remote merge host"), "\(codexRemoteHost) · " + (ok ? L("已连上（\(Fmt.agoShort(Int(Date().timeIntervalSince1970 - at))) 拉取）", "connected (fetched \(Fmt.agoShort(Int(Date().timeIntervalSince1970 - at))))") : L("未连上", "not connected"))))
        }
        for (id, b) in buckets.sorted(by: { $0.key < $1.key }) where id != "codex" {
            let label = b.name.isEmpty ? id : b.name
            if let w = b.weekly { d.extraPools.append(("\(label) \(L("周", "weekly"))", w)) }
            if let w = b.fiveHour { d.extraPools.append(("\(label) 5H", w)) }
        }
        d.sessions = sessionInfos(c, .codex)
        return d
    }

    func geminiDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.gemini/antigravity-cli/", "~/.config/vibegauge/agy-quota.json"]
        if let st = readJSON("\(home)/.gemini/antigravity-cli/settings.json"), let m = st["model"] as? String {
            d.rows.append((L("默认模型", "Default model"), m))
        }
        if let tok = readJSON("\(home)/.gemini/antigravity-cli/antigravity-oauth-token"), let m = tok["auth_method"] as? String {
            d.rows.append((L("鉴权方式", "Auth method"), m))
        }
        d.rows.append((L("三方池说明", "Third-party pool"), L("只有跑 Claude/GPT 模型时才会刷新；耗尽后无法再刷，只能等重置", "Refreshes only when running Claude/GPT models; once exhausted, wait for reset")))
        d.sessions = sessionInfos(c, .agy)
        return d
    }

    func grokDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.grok/settings_cache.json", "~/.grok/logs/unified.jsonl"]
        if let cache = readJSON("\(home)/.grok/settings_cache.json"),
           let payloadStr = cache["payload"] as? String,
           let pData = payloadStr.data(using: .utf8),
           let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let settings = pJson["settings"] as? [String: Any] {
            if let v = settings["subscription_tier_display"] as? String { d.rows.append((L("订阅档位（服务端原值）", "Subscription tier (server value)"), v)) }
            if let v = pJson["grok_version"] as? String { d.rows.append((L("CLI 版本", "CLI version"), v)) }
        }
        d.rows.append((L("额度来源", "Quota source"), L("grok 自己的 billing 日志，不必产生对话就会刷", "Grok billing logs; refreshes without a conversation")))
        d.sessions = sessionInfos(c, .grok)
        return d
    }

    func detectAllLLMRuntimes(_ c: SessionCounts) -> [DetectedLLMRuntime] {
        var list: [DetectedLLMRuntime] = []
        let fm = FileManager.default

        // Claude
        if c.claude > 0 || fm.fileExists(atPath: "\(home)/.claude.json") {
            let q = readClaudeQuota()
            let linked = StatuslineBridge.shared.isConnected(.claude)
            list.append(DetectedLLMRuntime(
                name: "Claude", isRunning: c.claude > 0, tier: getClaudeTier(), detail: L("\(c.claude) 会话", "\(c.claude) sessions"),
                fiveHour: q.fiveHour, sevenDay: q.sevenDay,
                secondaryPoolName: q.extraName, secondaryFiveHour: q.extra5h, secondarySevenDay: q.extraW,
                isFullWidth: !q.extraName.isEmpty,
                quotaSubtitle: linked ? L("Anthropic · 已连接，在 Claude Code 里发一条消息后显示", "Anthropic · connected, send a message in Claude Code")
                                      : L("Anthropic · 额度还没连接", "Anthropic · quota not connected"),
                connectTool: linked ? "" : "claude",
                platformDetail: claudeDetail(c)
            ))
        }

        // Codex（本机 + 远程合并；只显示主桶 codex）
        if c.codex > 0 || fm.fileExists(atPath: "\(home)/.codex/auth.json") {
            let q = codexSnapshot()
            var allBuckets = readLocalCodex().buckets
            remoteLock.lock(); let rb = remoteCodex.parsed.buckets; remoteLock.unlock()
            for (k, v) in rb where v.captured > (allBuckets[k]?.captured ?? -1) { allBuckets[k] = v }
            let hasRemote = !codexRemoteHost.isEmpty
            list.append(DetectedLLMRuntime(
                name: "Codex",
                isRunning: c.codex > 0,
                tier: getCodexTier(sessionPlan: q.plan),
                detail: L("\(c.codex) 会话", "\(c.codex) sessions"),
                fiveHour: q.primary?.fiveHour, sevenDay: q.primary?.weekly,
                quotaSubtitle: (hasRemote && !q.remoteOK) ? L("OpenAI · 无额度数据 (\(codexRemoteHost) 未连上)", "OpenAI · no quota data (\(codexRemoteHost) not connected)") : L("OpenAI · 无额度数据 (近两日无 session)", "OpenAI · no quota data (no session in the last 2 days)"),
                platformDetail: codexDetail(c, snapshot: q, buckets: allBuckets)
            ))
        }

        // Gemini / Antigravity（双池，独占整行）
        if c.agy > 0 || fm.fileExists(atPath: "\(home)/.gemini/antigravity-cli") {
            let q = readGeminiQuota()
            let linked = StatuslineBridge.shared.isConnected(.agy)
            let hasAny = q.native5h != nil || q.nativeW != nil || q.tp5h != nil || q.tpW != nil
            list.append(DetectedLLMRuntime(
                name: "Gemini", isRunning: c.agy > 0, tier: getGeminiTier(hasQuota: hasAny), detail: L("\(c.agy) 会话", "\(c.agy) sessions"),
                fiveHour: q.native5h, sevenDay: q.nativeW,
                secondaryPoolName: "三方", secondaryFiveHour: q.tp5h, secondarySevenDay: q.tpW,
                isFullWidth: hasAny,
                quotaSubtitle: linked ? L("Antigravity · 已连接，在 agy 里发一条消息后显示", "Antigravity · connected, send a message in agy")
                                      : L("Antigravity · 额度还没连接", "Antigravity · quota not connected"),
                connectTool: linked ? "" : "agy",
                platformDetail: geminiDetail(c)
            ))
        }

        // Grok（周额度来自 grok 自己的 billing 日志）
        if c.grok > 0 || fm.fileExists(atPath: "\(home)/.grok/auth.json") {
            let q = readGrokQuota()
            var tier = getGrokTier()
            if (tier == L("已登录", "Signed in") || tier == L("未登录", "Not signed in")), !q.tier.isEmpty { tier = q.tier }
            list.append(DetectedLLMRuntime(
                name: "Grok", isRunning: c.grok > 0, tier: tier, detail: L("\(c.grok) 会话", "\(c.grok) sessions"),
                sevenDay: q.weekly,
                quotaSubtitle: L("xAI · 无额度数据 (grok 未跑过)", "xAI · no quota data (grok has not run)"),
                platformDetail: grokDetail(c)
            ))
        }

        // Ollama（探测结果缓存 10s，避免 ticker 每秒阻塞）
        if c.ollama {
            let o = probeOllama()
            list.append(DetectedLLMRuntime(
                name: "Ollama", isRunning: o.count > 0, tier: L("本地", "Local"), detail: L("\(o.count) 模型", "\(o.count) models"), quotaSubtitle: o.sub
            ))
        }

        if c.cursor {
            list.append(DetectedLLMRuntime(name: "Cursor", isRunning: true, tier: "", detail: L("运行中", "Running"), quotaSubtitle: L("IDE 进程在线 · 本地无档位/额度数据", "IDE process online · no local tier/quota data")))
        }

        if c.lmStudio {
            list.append(DetectedLLMRuntime(name: "LM Studio", isRunning: true, tier: L("本地", "Local"), detail: L("运行中", "Running"), quotaSubtitle: L("端侧运行 · 0 额度消耗", "Runs locally · 0 quota used")))
        }

        return list
    }

    func probeOllama() -> (count: Int, sub: String) {
        let now = Date().timeIntervalSince1970
        if let c = ollamaCache, now - c.at < 10 { return (c.count, c.sub) }
        // 结果放独立加锁的盒子：超时后迟到的回调只写盒子，不与扫描线程的读竞争
        final class Box { let lock = NSLock(); var count = 0; var sub = L("端侧运行 · 无已加载模型", "Runs locally · no loaded models") }
        let box = Box()
        if let url = URL(string: "http://127.0.0.1:11434/api/ps") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.3
            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]], !models.isEmpty {
                    box.lock.lock()
                    box.count = models.count
                    box.sub = L("已加载: ", "Loaded: ") + models.compactMap { $0["name"] as? String }.joined(separator: ", ")
                    box.lock.unlock()
                }
                sema.signal()
            }.resume()
            _ = sema.wait(timeout: .now() + 0.3)
        }
        box.lock.lock()
        let result = (count: box.count, sub: box.sub)
        box.lock.unlock()
        ollamaCache = (result.count, result.sub, now)
        return result
    }
}
