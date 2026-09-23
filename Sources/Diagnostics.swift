import Cocoa

// `--diagnose`：本机诊断快照（排障用，输出可贴进 Issue）。读真实日志和网络，IP / 命令行已脱敏，
// 结果随机器而变，不做断言；断言放 SelfTest。
enum Diagnostics {
    /// 返回退出码：0 = 采完，1 = 后台首次采集超时（快照不完整）
    static func run() -> Int32 {
        let now = Date().timeIntervalSince1970
        NetworkScanner.shared.start()
        UsageHistory.shared.start()

        let t0 = Date()
        let r = ProcessScanner.shared.scan(refreshRemote: false)
        let t1 = Date()
        print(String(format: L("scan 耗时 %.0f ms", "scan: %.0f ms"), t1.timeIntervalSince(t0) * 1000))
        print(String(format: L("内存 可用%d%%  已用 %.1f/%.1f GB  swap %.2f GB  压缩 %.2f GB", "Memory free %d%%  used %.1f/%.1f GB  swap %.2f GB  compressed %.2f GB"), r.freePercentage, r.usedMemoryGB, r.totalMemoryGB, r.swapUsedGB, r.compressorGB))
        print(String(format: L("磁盘 剩余 %.1f/%.1f GB  负载 %.2f  NPX %.0f MB  MCP %d 进程 %.0f MB", "Disk free %.1f/%.1f GB  load %.2f  NPX %.0f MB  MCP %d processes %.0f MB"), r.diskFreeGB, r.diskTotalGB, r.loadAvg1m, r.npxCacheMB, r.activeMCPProcessCount, r.activeMCPTotalMemMB))
        print(L("孤儿 \(r.totalOrphanCount) 个 \(Int(r.totalOrphanMemMB)) MB: ", "Orphans \(r.totalOrphanCount), \(Int(r.totalOrphanMemMB)) MB: ") + r.orphanedGroups.map { "\($0.serviceName)x\($0.processCount)" }.joined(separator: ", "))
        if !r.orphans.isEmpty || !r.protected.isEmpty {
            print(L("--- 会被清理的（逐条）---", "--- To be reaped (each) ---"))
            for o in r.orphans { print(String(format: "  pid %-7d %5.0f MB  %@", o.pid, o.memMB, String(ProcessScanner.redactCommand(o.cmd).prefix(90)))) }
            print(L("--- 规则放过的（原因）---", "--- Protected by rules (reason) ---"))
            for p in r.protected { print(String(format: "  pid %-7d %5.0f MB  [%@]  %@", p.pid, p.memMB, p.reason, String(ProcessScanner.redactCommand(p.cmd).prefix(70)))) }
        }
        print(String(format: L("--- 磁盘：AI 工具目录合计 %.2f GB，可清理（%d 天前的会话记录）%.2f GB ---", "--- Disk: AI tool directories %.2f GB, reclaimable (sessions older than %d days) %.2f GB ---"),
                     r.diskTotalAIGB, ProcessScanner.shared.logRetentionDays, r.purgeableMB / 1024))
        for d in r.disk {
            print(String(format: L("  %@ %-16@ %7.0f MB (%d 文件)%@  %@", "  %@ %-16@ %7.0f MB (%d files)%@  %@"), d.purgeable ? "🧹" : "🔒", d.label, d.totalMB, d.files,
                         d.purgeable ? String(format: L("  其中旧 %.0f MB/%d 个", "  old %.0f MB/%d"), d.oldMB, d.oldFiles) : "", d.note))
        }
        print(L("--- 压力信号（图标画第一条）---", "--- Pressure signals (first is shown in the icon) ---"))
        for s in r.pressures.prefix(8) {
            print(String(format: L("  %-16@ %3d%%  线 %d/%d  margin %+d  level %d  %@", "  %-16@ %3d%%  thresholds %d/%d  margin %+d  level %d  %@"), s.short, s.pct, s.warn, s.crit, s.margin, s.level, s.detail))
        }
        print(L("--- 平台 ---", "--- Platforms ---"))
        func w(_ label: String, _ q: QuotaWindow?, _ profile: ActivityProfile? = nil) -> String {
            guard let q = q else { return "" }
            let reset = Fmt.countdown(to: q.resetsAt, now: now) ?? "?"
            let age = q.ageSeconds(now: now).map { Fmt.ago($0) } ?? "?"
            let burn = q.burn(now: now, profile: profile).map {
                ($0.perActiveDay.map { String(format: L(", %.1f%%/活跃天[%@]", ", %.1f%%/active day [%@]"), $0, q.lastCyclePct.map { "\($0)%" } ?? "—") } ?? "")
                + String(format: L(", %.1f%%/h→重置时 %d%%%@", ", %.1f%%/h → %d%% at reset%@"), $0.pctPerHour, $0.projectedAtReset,
                       $0.exhaustAt.flatMap { Fmt.countdown(to: $0, now: now) }.map { L(" ⚡\($0)后打满", " ⚡full in \($0)") } ?? "")
            } ?? ""
            return L("  \(label)=\(q.effectivePct(now: now))%(raw \(q.usedPct), 重置 \(reset), 采集 \(age)\(burn))", "  \(label)=\(q.effectivePct(now: now))% (raw \(q.usedPct), resets \(reset), captured \(age)\(burn))")
        }
        // 作息画像来自历史汇总：先等首轮汇总完，否则这里的周额度预测会全部退回旧算法
        let profileDeadline = Date().addingTimeInterval(120)
        while UsageHistory.shared.snapshot().capturedAt == 0 && Date() < profileDeadline { usleep(200_000) }
        let earlyHistory = UsageHistory.shared.snapshot()
        for l in r.detectedLLMs {
            let profile = earlyHistory.activityProfile(for: l.name)
            let secondaryPool = l.secondaryPoolName == "三方" ? L("三方", "3P") : l.secondaryPoolName
            print("\(l.isRunning ? "●" : "○") \(l.name) [\(l.tier)] \(l.detail)" + w("5H", l.fiveHour) + w("W", l.sevenDay, profile) + w("\(secondaryPool)5H", l.secondaryFiveHour) + w("\(secondaryPool)W", l.secondarySevenDay, profile) + (l.hasQuota ? "" : "  | \(l.quotaSubtitle)"))
        }
        let rs = ProcessScanner.shared.codexRemoteStatus()
        if rs.host.isEmpty { print(L("Codex 远程：未配置", "Codex remote: off")) }   // 主机名可能是 user@公网IP，不打印
        else { print(L("Codex 远程：已配置 · \(rs.ok ? "已连上" : "未连上") · \(rs.ageSeconds)s 前拉取", "Codex remote: configured · \(rs.ok ? "connected" : "not connected") · fetched \(rs.ageSeconds)s ago")) }
        let a = r.api
        let cov = a.coverage
        print(L("--- 记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处走代理 ---", "--- Accounting coverage: \(cov.proxiedCount)/\(cov.entries.count) via proxy ---"))
        for e in cov.entries { print("  \(e.proxied ? "✓" : "✗") \(e.name) → \(e.host)  (\(e.file):\(e.line))") }
        print(L("--- API 代理 --- 安装=\(a.installed) 运行=\(a.running) 端口=\(a.port) 启动后调用=\(a.callsSinceStart)", "--- API proxy --- installed=\(a.installed) running=\(a.running) port=\(a.port) calls since start=\(a.callsSinceStart)"))
        print(L("  价目表: ", "  Price table: ") + (a.hasPriceTable ? L("已配置 \(a.priceAsOf)", "configured \(a.priceAsOf)") : L("未配置（~/.config/vibegauge/prices.json）", "not configured (~/.config/vibegauge/prices.json)")))
        for p in a.providers {
            print(L("  \(p.provider) [\(p.host)] 今日 \(p.calls) 次 ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) 模型 \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.monthly.map { "M \($0.usedPct)%" } ?? "") \(p.quotaError)", "  \(p.provider) [\(p.host)] today \(p.calls) calls ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) models \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.monthly.map { "M \($0.usedPct)%" } ?? "") \(p.quotaError)"))
            print(String(format: L("    延迟 p50 %@ p95 %@ 最慢 %@ · 错误 %d(%.1f%%) 429 %d · 花费 %@ · key %@", "    latency p50 %@ p95 %@ slowest %@ · errors %d (%.1f%%) 429 %d · cost %@ · keys %@"),
                         Fmt.ms(p.p50ms), Fmt.ms(p.p95ms), Fmt.ms(p.maxms), p.errors, p.errorRate, p.count429,
                         p.cost.map { String(format: "%.4f %@", $0, p.costCurrency) } ?? "—",
                         p.keys.map { "\($0.fingerprint):\($0.calls)" }.joined(separator: " ")))
            if let hw = p.headerWindow { print(L("    限流头: \(p.headerLabel) 已用 \(hw.usedPct)% 重置 \(Fmt.countdown(to: hw.resetsAt, now: now) ?? "?")", "    rate-limit headers: \(p.headerLabel) \(hw.usedPct)% used, resets \(Fmt.countdown(to: hw.resetsAt, now: now) ?? "?" )")) }
            if p.quotaIsEstimate { print(L("    额度=估算 · \(p.estimateNote) · 上限 \(p.planLimitText)", "    quota=estimated · \(p.estimateNote) · limit \(p.planLimitText)")) }
        }
        print("--- Token ---")
        let t = r.tokens
        print(String(format: L("今日 %d 次调用  上下文 %lld  缓存读 %lld  命中 %.1f%%  输出 %lld  思考 %lld", "Today %d calls  context %lld  cache read %lld  hit %.1f%%  output %lld  reasoning %lld"), t.todayTurns, t.todayContext, t.todayCacheRead, t.todayCacheHitRate, t.todayOutput, t.todayThinking))
        for i in t.recentInteractions {
            print(String(format: "  %@ %@  ctx %d  out %d  think %d  hit %.1f%%  [%@]", Fmt.modelDisplayName(i.model), Fmt.ago(Int(now - i.timestamp)), i.contextTokens, i.outputTokens, i.thinkingTokens, i.cacheHitRate, i.id))
        }
        print(L("--- 今日按项目归因 ---", "--- Today by project ---"))
        for p in t.todayByProject.prefix(8) {
            print(String(format: L("  %-28@ %5d 轮  ctx %-10lld out %-8lld  [%@]", "  %-28@ %5d turns  ctx %-10lld out %-8lld  [%@]"), p.name, p.turns, p.ctx, p.out, p.clis.joined(separator: "+")))
        }
        print(L("--- 各 CLI 今日用量 ---", "--- Today's CLI usage ---"))
        for u in r.cliUsage {
            if u.hasTokens {
                print(String(format: L("  %@: ctx %lld  cache %lld  out %lld  think %lld  %d 次  命中 %.1f%%", "  %@: ctx %lld  cache %lld  out %lld  reasoning %lld  %d calls  hit %.1f%%"), u.name, u.ctx, u.cacheRead, u.out, u.think, u.requests, u.cacheHitRate))
            } else {
                print(L("  \(u.name): \(u.turns) 轮 · \(u.note)", "  \(u.name): \(u.turns) turns · \(u.note)"))
            }
        }

        let t2 = Date()
        _ = ProcessScanner.shared.scanTokens()
        _ = ProcessScanner.shared.scanActiveLLMs()
        print(String(format: L("二次轻量刷新耗时 %.0f ms (ticker 每秒跑的就是这个)", "Second light refresh: %.0f ms (this is what the 1s ticker runs)"), Date().timeIntervalSince(t2) * 1000))
        let historyDeadline = Date().addingTimeInterval(600)
        var timedOut = false
        var progressAt = Date.distantPast
        while UsageHistory.shared.snapshot().capturedAt == 0 || NetworkScanner.shared.snapshot().capturedAt == 0 {
            if Date() >= historyDeadline {
                print(L("后台首次采集超时，以下历史与网络部分不完整", "Background collection timed out; history and network below are incomplete"))
                timedOut = true
                break
            }
            if Date().timeIntervalSince(progressAt) > 15 {
                let progress = UsageHistory.shared.snapshot()
                print(L("历史汇总进度：\(progress.processedFiles)/\(progress.totalFiles) 文件", "History progress: \(progress.processedFiles)/\(progress.totalFiles) files"))
                progressAt = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let network = NetworkScanner.shared.snapshot()
        print(L("--- 网络 ---", "--- Network ---"))
        for item in network.aiExits where !item.isGemini {
            if item.error.isEmpty {
                print("\(item.name): \(maskedIP(item.ip)) · \(item.loc) · \(item.colo) · \(item.latencyMS)ms")
            } else { print(L("\(item.name): 查不到 · \(item.error)", "\(item.name): unavailable · \(item.error)")) }
        }
        let gemini = network.proxy.connections.first { $0.name == "Gemini" }
        print(L("Gemini: ", "Gemini: ") + (!network.proxy.error.isEmpty ? L("查不到出口：代理连接表不可用", "Egress unavailable: proxy connection table unavailable") : ((gemini?.count ?? 0) > 0 ? L("\(gemini!.count) 个活动连接 · 出站链路 \(gemini!.chains.count) 条", "\(gemini!.count) active connections · \(gemini!.chains.count) egress chains") : L("无活动连接，查不到出口", "No active connections; egress unavailable"))))
        print(L("代理内核: ", "Proxy core: ") + (network.proxy.error.isEmpty ? "\(network.proxy.version) · \(network.proxy.groups.count) \(L("个分组", "groups"))" : network.proxy.error))
        print(L("本机: \(network.local.interfaceName.isEmpty ? "查不到接口" : network.local.interfaceName) · 网关 \(maskedIP(network.local.gateway)) · IPv4 \(maskedIP(network.local.ipv4))", "Local: \(network.local.interfaceName.isEmpty ? "interface unavailable" : network.local.interfaceName) · gateway \(maskedIP(network.local.gateway)) · IPv4 \(maskedIP(network.local.ipv4))"))
        print("IPv6: \(network.leak.ipv6Message)" + (network.leak.ipv6Country.isEmpty ? "" : " · \(network.leak.ipv6Country)"))
        print("DNS: \(network.leak.dnsVerdict.localizedDescription)")
        let history = UsageHistory.shared.snapshot()
        print(L("--- 统计 ---", "--- Stats ---"))
        for name in ["Claude", "Codex", "*"] {
            let n = Int(history.hourCounts[name]?.reduce(0, +) ?? 0)
            let hours = history.hourCounts[name].flatMap(ActivityProfile.init(hourCounts:))?.activeHoursText ?? L("样本不足", "not enough data")
            print(L("作息 \(name): 近 7 天 \(n) 次调用 · 常用 \(hours)", "Pattern \(name): \(n) calls in 7 days · usual hours \(hours)"))
        }
        print(L("已处理 \(history.processedFiles)/\(history.totalFiles) 文件 · 自 \(history.earliestDate ?? "查不到最早日期") · \(history.activeDays) 个活跃日", "Processed \(history.processedFiles)/\(history.totalFiles) files · since \(history.earliestDate ?? "earliest date unavailable") · \(history.activeDays) active days"))
        print(L("累计 token \(history.tokenTotal) · 输入 \(history.ctx) · 缓存读 \(history.cacheRead) · 输出 \(history.aggregate.out)", "Total tokens \(history.tokenTotal) · input \(history.ctx) · cache read \(history.cacheRead) · output \(history.aggregate.out)"))
        print(L("缓存命中率 ", "Cache hit rate ") + (history.cacheHitRate.map { String(format: "%.2f%%", $0 * 100) } ?? L("查不到：无输入用量", "Unavailable: no input usage")))
        for source in ["Claude", "Codex"] {
            if let total = history.totals[source] { print(L("\(source): \(total.tokenTotal) token · \(total.turns) 请求 · \(total.sessions) 会话", "\(source): \(total.tokenTotal) tokens · \(total.turns) requests · \(total.sessions) sessions")) }
            else { print(L("\(source): 未检测到有效用量记录", "\(source): no valid usage records")) }
        }
        print(L("API 上游 \(history.totals.keys.filter { $0.hasPrefix("API · ") }.count) 个 · 累计差口径 \(history.cumulativeTurns) 次 · 跳过不完整记录 \(history.skippedRecords) 条", "API upstreams \(history.totals.keys.filter { $0.hasPrefix("API · ") }.count) · cumulative-delta records \(history.cumulativeTurns) · skipped incomplete records \(history.skippedRecords)"))
        print(L("API 等价成本: ", "API-equivalent cost: ") + (history.hasPriceTable ? (history.cost.map { String(format: "%.4f %@", $0, history.priceCurrency) } ?? L("未定价", "unpriced")) + (history.unpricedModels > 0 ? L(" · 部分模型未定价", " · some models unpriced") : "") : L("未配置价目表", "price table not configured")))
        if !history.error.isEmpty { print(L("汇总说明：\(history.error)", "Summary: \(history.error)")) }
        return timedOut ? 1 : 0
    }

    /// 输出会被贴进公开 Issue：IPv4 留前两段，IPv6 留前两组
    static func maskedIP(_ ip: String) -> String {
        if ip.contains(":") { return ip.split(separator: ":").prefix(2).joined(separator: ":") + ":x:x" }
        let parts = ip.split(separator: ".")
        return parts.count == 4 ? parts.prefix(2).joined(separator: ".") + ".x.x" : L("查不到", "Unavailable")
    }
}
