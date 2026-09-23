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
        let a = claudeAnomalies
        if !a.failures.isEmpty {
            d.rows.append((L("今日请求失败", "Failed requests today"), RequestAnomalies.text(a.failures)))
        }
        if !a.retries.isEmpty {
            d.rows.append((L("今日自动重试", "Automatic retries today"), RequestAnomalies.text(a.retries)))
        }
        if let t = a.lastAt { d.rows.append((L("最近一次异常", "Last error"), Fmt.agoShort(Int(Date().timeIntervalSince1970 - t)))) }
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

        // Kimi Code：官方本机服务（kimi web）的用量接口，5h / 周 / 月都是官方回报
        if fm.fileExists(atPath: "\(home)/.kimi-code") {
            let k = readKimiQuota()
            var card = DetectedLLMRuntime(
                name: "Kimi Code", isRunning: c.kimi > 0, tier: k.tier, detail: L("\(c.kimi) 会话", "\(c.kimi) sessions"),
                fiveHour: k.fiveHour, sevenDay: k.week,
                quotaSubtitle: k.note)
            card.monthly = k.month
            card.isFullWidth = k.fiveHour != nil || k.week != nil || k.month != nil
            card.extraLine = k.extra
            list.append(card)
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

        // 本机模型服务：只读 GET（不会触发加载模型），10s 缓存。服务在线但没加载模型 = 在线，不是「未运行」
        if c.ollama {
            if let j = probeLocalJSON("http://127.0.0.1:11434/api/ps") as? [String: Any] {
                let names = (j["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                list.append(localCard("Ollama", loaded: names))
            } else {
                list.append(DetectedLLMRuntime(name: "Ollama", isRunning: false, tier: L("本地", "Local"), detail: L("状态未知", "Status unknown"),
                    quotaSubtitle: L("进程在跑，但 127.0.0.1:11434 没应答（改过 OLLAMA_HOST？）", "Process running but 127.0.0.1:11434 is not answering (custom OLLAMA_HOST?)")))
            }
        }

        if c.cursor {
            list.append(DetectedLLMRuntime(name: "Cursor", isRunning: true, tier: "", detail: L("运行中", "Running"), quotaSubtitle: L("IDE 进程在线 · 本地无档位/额度数据", "IDE process online · no local tier/quota data")))
        }

        if c.lmStudio {
            // v1 REST：models[].loaded_instances；旧版回退 v0：data[].state == "loaded"。/v1/models 列的是可用模型（JIT），不能当已加载
            if let j = probeLocalJSON("http://127.0.0.1:1234/api/v1/models") as? [String: Any], let models = j["models"] as? [[String: Any]] {
                let names = models.filter { !($0["loaded_instances"] as? [Any] ?? []).isEmpty }.compactMap { ($0["key"] ?? $0["id"]) as? String }
                list.append(localCard("LM Studio", loaded: names))
            } else if let j = probeLocalJSON("http://127.0.0.1:1234/api/v0/models") as? [String: Any], let data = j["data"] as? [[String: Any]] {
                list.append(localCard("LM Studio", loaded: data.filter { $0["state"] as? String == "loaded" }.compactMap { $0["id"] as? String }))
            } else {
                list.append(DetectedLLMRuntime(name: "LM Studio", isRunning: true, tier: L("本地", "Local"), detail: L("运行中", "Running"),
                    quotaSubtitle: L("App 在跑 · 本地服务未开启（Developer → Start Server）", "App running · local server off (Developer → Start Server)")))
            }
        }

        for port in Set(c.llamaServerPorts).sorted() {
            // llama-server 一次只服务一个模型，/v1/models 列的就是它
            let ids = ((probeLocalJSON("http://127.0.0.1:\(port)/v1/models") as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
            list.append(ids.map { localCard("llama.cpp :\(port)", loaded: $0) } ?? DetectedLLMRuntime(name: "llama.cpp :\(port)", isRunning: false, tier: L("本地", "Local"),
                detail: L("状态未知", "Status unknown"), quotaSubtitle: L("进程在跑，端口没应答（还在加载模型？）", "Process running, port not answering (still loading?)")))
        }
        for port in Set(c.mlxServerPorts).sorted() {
            // mlx_lm.server 的 /v1/models 列的是本机缓存的模型，不代表已加载 → 只报在线
            let online = probeLocalJSON("http://127.0.0.1:\(port)/v1/models") != nil
            list.append(DetectedLLMRuntime(name: "MLX :\(port)", isRunning: online, tier: L("本地", "Local"), detail: online ? L("在线", "Online") : L("状态未知", "Status unknown"),
                quotaSubtitle: online ? L("端侧运行 · 0 额度消耗", "Runs locally · 0 quota used") : L("进程在跑，端口没应答", "Process running, port not answering")))
        }

        return list
    }

    func localCard(_ name: String, loaded: [String]) -> DetectedLLMRuntime {
        DetectedLLMRuntime(name: name, isRunning: true, tier: L("本地", "Local"),
                           detail: loaded.isEmpty ? L("在线", "Online") : L("\(loaded.count) 模型", "\(loaded.count) models"),
                           quotaSubtitle: loaded.isEmpty ? L("在线 · 无已加载模型", "Online · no model loaded") : L("已加载: ", "Loaded: ") + loaded.joined(separator: ", "))
    }

    /// 本机 HTTP GET，0.3s 超时，结果缓存 10s（失败也缓存，免得每秒卡一次）。
    /// 结果放独立加锁的盒子：超时后迟到的回调只写盒子，不与扫描线程的读竞争。非 2xx / 非 JSON = nil。
    /// ponytail: 同步等待，在扫描锁内；多个本机服务同时不可达时最坏每 10s 多等 0.3s × 个数，要更快再改异步快照
    func probeLocalJSON(_ urlString: String, headers: [String: String] = [:]) -> Any? {
        let now = Date().timeIntervalSince1970
        if let c = localProbeCache[urlString], now - c.at < 10 { return c.json }
        final class Box { let lock = NSLock(); var json: Any? }
        let box = Box()
        if let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.3
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let sema = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    box.lock.lock(); box.json = json; box.lock.unlock()
                }
                sema.signal()
            }
            task.resume()
            if sema.wait(timeout: .now() + 0.3) == .timedOut { task.cancel() }
        }
        box.lock.lock(); let result = box.json; box.lock.unlock()
        localProbeCache[urlString] = (now, result)
        return result
    }
}
