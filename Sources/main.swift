import Cocoa

// `VibeGauge --install-proxy` / `--uninstall-proxy`：命令行装卸 API 记账代理（与菜单同一条代码路径）
if CommandLine.arguments.contains("--install-proxy") {
    do {
        try ProxyManager.shared.install()
        print(L("已安装并启动：\(ProxyManager.shared.prefix)  日志 \(ProxyManager.shared.logPath)", "Installed and started: \(ProxyManager.shared.prefix)  log \(ProxyManager.shared.logPath)"))
    } catch {
        print(L("安装失败：\(error.localizedDescription)", "Installation failed: \(error.localizedDescription)"))
        exit(1)
    }
    exit(0)
}
if CommandLine.arguments.contains("--uninstall-proxy") {
    ProxyManager.shared.uninstall()
    print(L("已卸载", "Uninstalled"))
    exit(0)
}

// `VibeGauge --selftest`：不起 UI，校验纯函数 + 打印一次完整扫描结果（档位/额度/Token 去重后数据）
if CommandLine.arguments.contains("--selftest") {
    precondition(Fmt.modelDisplayName("claude-fable-5-1") == "Fable 5.1")
    precondition(Fmt.modelDisplayName("claude-opus-5") == "Opus 5")
    precondition(Fmt.modelDisplayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
    precondition(Fmt.modelDisplayName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
    precondition(ProcessScanner.codexPlanLabel("prolite") == "Pro Lite")
    precondition(ProcessScanner.codexPlanLabel("plus") == "Plus")
    let now = Date().timeIntervalSince1970
    precondition(QuotaWindow(usedPct: 66, resetsAt: now - 1, capturedAt: nil).effectivePct(now: now) == 0)
    precondition(QuotaWindow(usedPct: 66, resetsAt: now + 100, capturedAt: nil).effectivePct(now: now) == 66)
    precondition(Fmt.countdown(to: now + 90, now: now) == "1m")
    precondition(Fmt.countdown(to: now + 6540, now: now) == "1h49m")
    precondition(Fmt.countdown(to: now + 2 * 86400 + 10 * 3600, now: now) == "2d10h")
    precondition(Fmt.countdown(to: now - 5, now: now) == L("已重置", "Reset"))
    precondition(Fmt.parseISODate("2026-09-19T10:34:27.346461+00:00") != nil)   // grok 6 位小数秒
    precondition(Fmt.parseISODate("2026-09-17T09:07:45.133Z") != nil)           // claude 3 位
    precondition(Fmt.parseISODate("2026-09-17T03:14:39Z") != nil)               // 无小数

    // 探测只看可执行文件路径：别人 grep 这些名字不该算"在跑"
    precondition(ProcessScanner.isClaudeCLISession(cmd: "claude --resume abc"))
    precondition(!ProcessScanner.isClaudeCLISession(cmd: "/bin/zsh -c ps -ax | grep claude"))
    precondition(ProcessScanner.isCodexCLISession(cmd: "node /Users/x/.npm-global/bin/codex --foo"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "/Users/x/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "ssh host codex mcp-server"))

    // Codex 额度耗尽文案里的重置时刻
    precondition(Fmt.parseUsageLimitReset("You've hit your usage limit. Visit https://x to purchase more credits or try again at Sep 19th, 2026 5:03 PM.") != nil)
    precondition(Fmt.parseUsageLimitReset("try again at Oct 1st, 2026 12:00 AM") != nil)
    precondition(Fmt.parseUsageLimitReset("no reset info here") == nil)

    // 压力信号排序：按"离各自报警线的距离"，不按百分比（内存 60% 不该压住额度 55%）
    do {
        var s = ScanReport()
        s.totalMemoryGB = 64; s.freePercentage = 40          // 内存已用 60%，线 85 → margin -25
        s.diskTotalGB = 1000; s.diskFreeGB = 500; s.diskFreePct = 50   // 已用 50%，线 90 → margin -40
        s.detectedLLMs = [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "",
                                             fiveHour: QuotaWindow(usedPct: 55, resetsAt: now + 3600, capturedAt: now))]
        precondition(s.tightest?.short == L("内存", "Memory"), "60% 内存该压住 55% 额度（离线更近）")
        precondition(s.tightest?.level == 0)
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 82, resetsAt: now + 3600, capturedAt: now)
        precondition(s.tightest?.short == "Claude 5h" && s.tightest?.level == 1, "额度 82% 越线 → 最紧且报警")
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 99, resetsAt: now - 1, capturedAt: now)
        precondition(s.pressures.first(where: { $0.short == "Claude 5h" })?.pct == 0, "过了重置点的旧值不许再报警")
        precondition(s.pressures.contains { $0.short == L("磁盘", "Disk") })
    }

    // 百分位取最近秩：p95 一定落在某次真实调用上
    precondition(Fmt.percentile([100], 0.95) == 100)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
    precondition(Fmt.percentile([], 0.5) == 0)
    precondition(Fmt.ms(0) == "—" && Fmt.ms(312) == "312ms" && Fmt.ms(4298) == "4.3s" && Fmt.ms(62_000) == "1m02s")

    // 价目表：ctx 是"全部输入"，算价前要把缓存读/写扣出来，否则新鲜 token 会被重复计价
    do {
        let t = ProcessScanner.PriceTable(json: [
            "_currency": "CNY", "_asof": "2026-09-18",
            "glm-4.7": ["in": 4.0, "cache_read": 1.0, "cache_write": 5.0, "out": 12.0],
            "zero-price-placeholder": ["in": 0, "out": 0],
        ])
        // 新鲜 60w + 缓存读 30w + 缓存写 10w + 输出 10w
        let c = t.cost(model: "glm-4.7", ctx: 1_000_000, cacheRead: 300_000, cacheWrite: 100_000, out: 100_000)!
        precondition(abs(c - (0.6 * 4.0 + 0.3 * 1.0 + 0.1 * 5.0 + 0.1 * 12.0)) < 1e-9, "算出来 \(c)")
        precondition(t.cost(model: "glm-4.7-flash", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0) != nil, "前缀命中")
        precondition(t.cost(model: "unknown-model", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "没价的模型不许估")
        precondition(t.cost(model: "zero-price-placeholder", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "占位行不算价")
        precondition(ProcessScanner.PriceTable().isEmpty)
    }

    // 订阅制 Coding Plan 的额度估算：滚动窗口内的请求数 ÷ 上限
    do {
        let stamps: [TimeInterval] = (0..<600).map { now - Double($0) * 10 }      // 最近 100 分钟里 600 次
        let w = ProcessScanner.rollingWindow(stamps, seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(w.usedPct == 50, "600/1200 该是 50%，实际 \(w.usedPct)")
        precondition(abs((w.resetsAt ?? 0) - (stamps.min()! + 5 * 3600)) < 1, "重置点 = 窗口内最早一次 + 窗口长")
        let old = ProcessScanner.rollingWindow([now - 6 * 3600], seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(old.usedPct == 0, "窗口外的调用不该算")
        precondition(ProcessScanner.rollingWindow(stamps, seconds: 3600, limit: 0, now: now) == nil, "没填上限就不估")
    }

    // 内存吃紧才立刻收割，且 5 分钟内不重复
    precondition(AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: 0, now: now))
    precondition(!AppDelegate.shouldReapForMemory(usedPct: 60, lastCleanAt: 0, now: now), "内存不紧就别动")
    precondition(!AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: now - 60, now: now), "1 分钟前刚清过")
    precondition(AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: now - 400, now: now))

    // 限流响应头 → 额度（各家写法不同，统一按"去掉 limit/remaining/reset 后同族"配对）
    do {
        // Anthropic：族名在前，reset 是 ISO8601
        let a = ProcessScanner.parseRateLimitHeaders([
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "900",
            "anthropic-ratelimit-requests-reset": "2026-09-18T12:00:00Z",
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "20000",      // 更紧 → 应该选这族
            "anthropic-ratelimit-tokens-reset": "2026-09-18T12:00:00Z",
        ], now: now)!
        precondition(a.usedPct == 80 && a.label == "tokens", "实际 \(a)")
        precondition(a.resetsAt != nil)

        // OpenAI：kind 在中间，reset 是时长
        let o = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit-requests": "500",
            "x-ratelimit-remaining-requests": "125",
            "x-ratelimit-reset-requests": "6m0s",
        ], now: now)!
        precondition(o.usedPct == 75 && o.label == "requests", "实际 \(o)")
        precondition(abs((o.resetsAt ?? 0) - (now + 360)) < 1, "6m0s = 360 秒")

        // GitHub/通用：epoch 秒（真实抓的样本形态）
        let g = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit": "60", "x-ratelimit-remaining": "58",
            "x-ratelimit-used": "2", "x-ratelimit-resource": "core",
            "x-ratelimit-reset": "1789727826",
        ], now: now)!
        precondition(g.usedPct == 3, "58/60 → 已用 3%，实际 \(g.usedPct)")
        precondition(abs((g.resetsAt ?? 0) - 1789727826) < 1)

        // 毫秒时间戳 / 纯相对秒数
        precondition(abs((ProcessScanner.parseResetValue("1789727826000", now: now) ?? 0) - 1789727826) < 1)
        precondition(abs((ProcessScanner.parseResetValue("30", now: now) ?? 0) - (now + 30)) < 1)
        precondition(abs((ProcessScanner.parseResetValue("1h2m3s", now: now) ?? 0) - (now + 3723)) < 1)
        // 没有 limit/remaining 配对就不瞎猜
        precondition(ProcessScanner.parseRateLimitHeaders(["x-ratelimit-reset": "60"], now: now) == nil)
        precondition(ProcessScanner.parseRateLimitHeaders(["content-type": "application/json"], now: now) == nil)
    }

    // 记账覆盖体检：只抠变量名与主机，同一行的 key 一律不碰
    do {
        let pfx = "http://127.0.0.1:18790/"
        let a = ProcessScanner.parseBaseURLLine("  export ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic", proxyPrefix: pfx)!
        precondition(a.name == "ANTHROPIC_BASE_URL" && a.host == "open.bigmodel.cn" && a.proxied)
        let b = ProcessScanner.parseBaseURLLine("OPENAI_API_BASE='https://api.deepseek.com/v1'", proxyPrefix: pfx)!
        precondition(b.host == "api.deepseek.com" && !b.proxied)
        precondition(ProcessScanner.parseBaseURLLine("# ANTHROPIC_BASE_URL=https://x.com", proxyPrefix: pfx) == nil, "注释行不算")
        precondition(ProcessScanner.parseBaseURLLine("export ANTHROPIC_API_KEY=sk-ant-xxxx", proxyPrefix: pfx) == nil, "key 行不该被当成 BASE_URL")
        precondition(ProcessScanner.parseBaseURLLine("alias cc='claude'", proxyPrefix: pfx) == nil)
        // zsh 里这些行普遍以续行符结尾，别被它吃掉
        let c = ProcessScanner.parseBaseURLLine("    ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://openrouter.ai/api \\", proxyPrefix: pfx)!
        precondition(c.host == "openrouter.ai" && c.proxied, "实际 \(c)")
        let d = ProcessScanner.parseBaseURLLine("  ANTHROPIC_BASE_URL=\"http://127.0.0.1:18790/http://localhost:18080\" \\", proxyPrefix: pfx)!
        precondition(d.host == "localhost:18080" && d.proxied, "实际 \(d)")
    }

    // 燃烧速率：窗口长度 + 重置点 → 不用攒历史采样
    do {
        // 5h 窗口过了 1 小时用掉 20% → 4%/h，到重置(还剩 4h)会到 100%
        let w = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        let b = w.burn(now: now)!
        precondition(abs(b.pctPerHour - 20.0) < 0.01, "1 小时用 20% = 20%/h，实际 \(b.pctPerHour)")
        precondition(b.projectedAtReset == 100, "实际 \(b.projectedAtReset)")
        precondition(b.exhaustAt != nil && abs(b.exhaustAt! - (now + 4 * 3600)) < 60)
        // 慢速：4h 才用 10% → 到重置只有 12%，不该报"会打满"
        let slow = QuotaWindow(usedPct: 10, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600)
        precondition(slow.burn(now: now)!.exhaustAt == nil)
        // 窗口刚开头 / 没窗口长度 / 已过重置 → 一律不推算，不瞎猜
        precondition(QuotaWindow(usedPct: 5, resetsAt: now + 17_500, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)  // 窗口才过 500 秒
        precondition(QuotaWindow(usedPct: 50, resetsAt: now + 3600, capturedAt: now).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 50, resetsAt: now - 1, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 100, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil, "已打满不推算")

        // 近期速度优先：窗口均速只有 4%/h，但近 30 分钟在以 60%/h 猛烧 → 必须按近期算
        var hot = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        hot.recentPctPerHour = 60; hot.recentSpanMinutes = 30
        let hb = hot.burn(now: now)!
        precondition(hb.isRecent && hb.basis == L("近 30 分钟", "last 30m"))
        precondition(hb.projectedAtReset == 260, "20 + 60*4 = 260，实际 \(hb.projectedAtReset)")
        precondition(hb.exhaustAt != nil && abs(hb.exhaustAt! - (now + 80.0 / 60 * 3600)) < 60)
        // 跨度不足 10 分钟 → 噪声太大，退回窗口均速
        var noisy = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        noisy.recentPctPerHour = 60; noisy.recentSpanMinutes = 3
        precondition(noisy.burn(now: now)!.basis == L("本窗口均", "window average"))
        // 有近期速度时，窗口刚开头也能算（不必等满 15 分钟）
        var early = QuotaWindow(usedPct: 2, resetsAt: now + 17_700, capturedAt: now, windowSeconds: 5 * 3600)
        early.recentPctPerHour = 12; early.recentSpanMinutes = 15
        precondition(early.burn(now: now)?.isRecent == true)
    }

    // 版本号比较：逐段按数字，不是按字符串
    precondition(UpdateChecker.isNewer("v1.10.0", than: "1.9.2") && UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
    precondition(!UpdateChecker.isNewer("1.1.0", than: "1.1.0") && !UpdateChecker.isNewer("v1.1", than: "1.1.0"))
    precondition(!UpdateChecker.isNewer("", than: "1.0.0") && UpdateChecker.isNewer("2", than: "1.99.99"))

    // 按作息推算（周窗口）：只在 10 点到次日 2 点用，睡觉的 8 小时几乎不算
    do {
        let utc = TimeZone(identifier: "UTC")!
        let day0 = 1_789_948_800.0                      // 某天 UTC 0 点
        func hourOf(_ t: TimeInterval) -> Int { Int(t.truncatingRemainder(dividingBy: 86400) / 3600) }
        var counts = [Double](repeating: 0, count: 24)
        for h in [0, 1] + Array(10...23) { counts[h] = 10 }
        let p = ActivityProfile(hourCounts: counts)!
        precondition(abs(p.share.reduce(0, +) - 1) < 1e-9)
        precondition(abs(p.activeDays(from: day0, to: day0 + 86400, timeZone: utc) - 1) < 1e-9, "整一天 = 1 个活跃天")
        let night = p.activeDays(from: day0 + 2 * 3600, to: day0 + 10 * 3600, timeZone: utc)
        precondition(night < 0.04, "睡觉的 8 小时不到 0.04 个活跃天，实际 \(night)")
        precondition(p.activeHoursText == L("10–02 点", "10–02"), "实际 \(p.activeHoursText)")
        precondition(ActivityProfile(hourCounts: [Double](repeating: 10, count: 24))!.activeHoursText == L("全天", "all day"))
        var few = [Double](repeating: 0, count: 24); few[9] = 40; few[10] = 40
        precondition(ActivityProfile(hourCounts: few) == nil, "只有 2 个钟点有记录 → 不画像")
        precondition(ActivityProfile(hourCounts: counts.map { $0 / 10 }) == nil, "近 7 天不足 30 次 → 不画像")
        let hc = ActivityProfile.hourCounts([day0 + 10 * 3600 + 5, day0 + 23 * 3600, day0 - 8 * 86400], now: day0 + 86400, timeZone: utc)
        precondition(hc[10] == 1 && hc[23] == 1 && hc.reduce(0, +) == 2, "8 天前那条不算")

        // day0 10 点起的周窗口；第 3 天凌晨 2 点（刚睡）已用 45%，睡到 10 点用量没变
        let reset = day0 + 10 * 3600 + 7 * 86400
        let w = QuotaWindow(usedPct: 45, resetsAt: reset, capturedAt: day0, windowSeconds: 7 * 86400)
        let atSleep = day0 + 3 * 86400 + 2 * 3600, wake = atSleep + 8 * 3600
        let s1 = w.burn(now: atSleep, profile: p, timeZone: utc)!, s2 = w.burn(now: wake, profile: p, timeZone: utc)!
        precondition(s1.perActiveDay != nil && w.burn(now: atSleep)!.perActiveDay == nil)
        precondition(abs(s1.projectedAtReset - s2.projectedAtReset) <= 2, "睡一觉不该改变预测：\(s1.projectedAtReset) vs \(s2.projectedAtReset)")
        let o1 = w.burn(now: atSleep)!.projectedAtReset, o2 = w.burn(now: wake)!.projectedAtReset
        precondition(o1 - o2 > 10, "旧算法把整晚当在用，同样用量两个时刻差 \(o1 - o2)")
        // 用得猛会打满：打满时刻必须落在常用时段，不会算在睡觉时
        let heavy = QuotaWindow(usedPct: 60, resetsAt: reset, capturedAt: day0, windowSeconds: 7 * 86400)
        let hb = heavy.burn(now: atSleep, profile: p, timeZone: utc)!
        precondition(hb.projectedAtReset > 100 && hb.exhaustAt! < reset, "实际 \(hb.projectedAtReset)")
        precondition(counts[hourOf(hb.exhaustAt!)] > 0, "打满时刻 \(hourOf(hb.exhaustAt!)) 点不在常用时段")

        // 刚重置 1 小时就用了 5%：没有上周期 → 样本不够不推算；有上周期 70% → 先信上周期，不会外推出几百
        var fresh = QuotaWindow(usedPct: 5, resetsAt: reset, capturedAt: day0, windowSeconds: 7 * 86400)
        let justAfter = day0 + 11 * 3600
        precondition(fresh.burn(now: justAfter, profile: p, timeZone: utc) == nil)
        precondition(fresh.burn(now: justAfter)!.projectedAtReset > 500, "旧算法：1 小时 5% × 167 小时")
        fresh.lastCyclePct = 70
        let fb = fresh.burn(now: justAfter, profile: p, timeZone: utc)!
        precondition((70...120).contains(fb.projectedAtReset), "有上周期兜底，实际 \(fb.projectedAtReset)")
        precondition(fb.basis == L("作息 · 上周期 70%", "pattern · last 70%"))
        // 非整点夏令时（查塔姆群岛 02:45 跳 03:45）：与逐 30 秒积分对照
        let chatham = TimeZone(identifier: "Pacific/Chatham")!
        if let dst = chatham.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: day0))?.timeIntervalSince1970 {
            var spiky = [Double](repeating: 0, count: 24); spiky[1] = 100; spiky[2] = 100; spiky[10] = 100
            let sp = ActivityProfile(hourCounts: spiky)!
            func share(_ t: TimeInterval) -> Double {
                let local = t + Double(chatham.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
                return sp.share[(Int((local / 3600).rounded(.down)) % 24 + 24) % 24]
            }
            let a = dst - 20 * 3600, b = dst + 20 * 3600
            let brute = stride(from: a, to: b, by: 30).reduce(0.0) { $0 + share($1) * 30 / 3600 }
            let fast = sp.activeDays(from: a, to: b, timeZone: chatham)
            precondition(abs(fast - brute) < 0.002, "跨夏令时积分 \(fast) vs 逐秒 \(brute)")
            var used = 0.0, bruteAt = b
            for t in stride(from: a, to: b, by: 30) { used += 100 * share(t) * 30 / 3600; if used >= 60 { bruteAt = t; break } }
            let at = sp.exhaustTime(from: a, limit: b, need: 60, perDay: 100, timeZone: chatham)!
            precondition(abs(at - bruteAt) < 120, "跨夏令时打满时刻差 \(at - bruteAt) 秒")
        }
        // 5h 窗口不受作息影响
        let five = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        precondition(five.burn(now: now, profile: p) == five.burn(now: now))

        // 上周期终值：取重置前最后一笔；数据源滞后时重置后用旧重置点记的 0% 不算
        let samples: [String: [(t: TimeInterval, pct: Int)]] = [
            "Claude|w@1000": [(t: 900, pct: 60), (t: 990, pct: 72), (t: 1010, pct: 0)],
            "Claude|w@2000": [(t: 1500, pct: 10)],
            "Claude|5h@1000": [(t: 990, pct: 99)],
        ]
        let fin = ProcessScanner.finishedCycle(samples, rawKey: "Claude|w", now: 1500)!
        precondition(fin.reset == 1000 && fin.pct == 72, "实际 \(fin)")
        precondition(ProcessScanner.finishedCycle(samples, rawKey: "Claude|w", now: 1500) != nil)
        precondition(ProcessScanner.finishedCycle(samples, rawKey: "Claude|w", now: 999) == nil, "还没到重置点")
        // 合盖一晚跨过周重置：一次归档把周和 5h 的终值都存下，之后清掉过期样本也不丢
        var all = samples
        ProcessScanner.archiveFinals(&all, now: 1500)
        precondition(all["final|Claude|w"]?.last?.pct == 72 && all["final|Claude|5h"]?.last?.pct == 99)
        precondition(all["final|Claude|w"]?.last?.t == 1000)
    }

    // 会话日志保留期硬下限 7 天（本工具自己要读近两天的文件算额度）
    precondition(ProcessScanner.effectiveRetention(30) == 30)
    precondition(ProcessScanner.effectiveRetention(3) == 7)
    precondition(ProcessScanner.effectiveRetention(0) == 7)
    precondition(ProcessScanner.effectiveRetention(-99) == 7)

    // ssh 主机名会被拼进 shell 命令 → 只放行合法主机名
    precondition(ProcessScanner.isValidSSHHost("fixture-host"))
    precondition(ProcessScanner.isValidSSHHost("fixture@192.0.2.9"))
    precondition(!ProcessScanner.isValidSSHHost("-Fx"))
    precondition(!ProcessScanner.isValidSSHHost("-oProxyCommand=x"))
    precondition(!ProcessScanner.isValidSSHHost("-fixture@host"))
    precondition(!ProcessScanner.isValidSSHHost("fixture@-host"))
    precondition(!ProcessScanner.isValidSSHHost("fixture-host; rm -rf ~"))
    precondition(!ProcessScanner.isValidSSHHost("$(whoami)"))
    precondition(!ProcessScanner.isValidSSHHost("a`id`b"))
    precondition(!ProcessScanner.isValidSSHHost(""))

    // 网络解析只用文档地址；不把本机出口、节点或账户信息写进测试。
    do {
        let trace = parseTrace("fl=fixture\nip=192.0.2.7\nloc=US\ncolo=SJC\n")!
        precondition(trace.ip == "192.0.2.7" && trace.loc == "US" && trace.colo == "SJC")
        precondition(parseTrace(" colo=NRT\r\nloc=JP\r\nip=198.51.100.8\r\n")?.colo == "NRT")
        precondition(parseTrace("ip=not-an-ip\nloc=US\ncolo=SJC") == nil)
        precondition(parseTrace("ip=192.0.2.7\nloc=US") == nil)
        precondition(parseTrace("<html>unavailable</html>") == nil)
        precondition(rate(prev: UInt64(100), cur: 300, dt: 2) == 100)
        precondition(rate(prev: UInt64(100), cur: 100, dt: 2) == 0)
        precondition(rate(prev: UInt64.max, cur: 2, dt: 2) == nil)
        precondition(rate(prev: UInt64(100), cur: 1, dt: 2) == nil)
        precondition(rate(prev: UInt64(0), cur: 1, dt: 0) == nil)
        precondition(rate(prev: UInt64(0), cur: 1, dt: .infinity) == nil)
        precondition(rate(prev: Int64(-1), cur: 1, dt: 2) == nil)
        precondition(ipv6Verdict(traceIP: "149.119.151.8", httpStatus: 200).blocked)  // IPv4 映射：走隧道，不是泄漏
        precondition(!ipv6Verdict(traceIP: "240e:390::1", httpStatus: 200).blocked)
        precondition(ipv6Verdict(traceIP: nil, httpStatus: 0).blocked)
        precondition(!ipv6Verdict(traceIP: nil, httpStatus: 200).blocked)
        precondition(dnsVerdict([]) == .unknown)
        precondition(dnsVerdict(["192.0.2.1"]) == .unknown)
        precondition(dnsVerdict(["198.18.0.1", "127.0.0.1"]) == .proxyOK)
        precondition(dnsVerdict(["198.19.255.254"]) == .proxyOK)
        precondition(dnsVerdict(["198.20.0.1"]) == .unknown)
        precondition(dnsVerdict(["198.18.0.999"]) == .unknown)
        precondition(dnsVerdict(["127.0.0.1", "192.0.2.1"]) == .unknown)
        // 这是 DNS 规则中必须识别的公共服务地址，不是本机或节点地址。
        precondition(dnsVerdict(["127.0.0.1", "223.5.5.5"]) == .domesticWarning)
        let dns = "nameserver[0] : 203.0.113.1\nresolver #11\n nameserver[0] : 203.0.113.2\nresolver #1\n nameserver[0] : 192.0.2.1\n nameserver[1] : 198.51.100.1\nresolver #2\n nameserver[0] : 203.0.113.3"
        precondition(NetworkScanner.parseDNS(dns) == ["192.0.2.1", "198.51.100.1"])
        precondition(NetworkScanner.parseDNS("resolver #1\n nameserver[0] : 192.0.2.1\nresolver #1\n nameserver[0] : 203.0.113.1") == ["192.0.2.1"])
        let counters = NetworkScanner.parseNetstat("Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#1> fixture 1 0 1024 2 0 2048 0", iface: "en0")!
        precondition(counters.input == 1024 && counters.output == 2048)
        precondition(NetworkScanner.parseNetstat("no counters", iface: "en0") == nil)
        precondition(NetworkScanner.isGlobalIPv6("2001:db8::1"))
        precondition(!NetworkScanner.isGlobalIPv6("fe80::1") && !NetworkScanner.isGlobalIPv6("fd00::1"))
        precondition(NetworkScanner.validatedClashURL("http://127.0.0.1:9090") != nil)
        precondition(NetworkScanner.validatedClashURL("http://localhost:9090")?.host == "127.0.0.1")
        precondition(NetworkScanner.validatedClashURL("http://192.0.2.1:9090") == nil)
        precondition(NetworkScanner.validatedClashURL("http://127.0.0.1:9090/?url=fixture") == nil)
        let connections = NetworkScanner.parseConnections(["connections": [
            ["metadata": ["host": "API.OPENAI.COM."], "chains": ["fixture-exit", "fixture-select"], "rule": "DomainSuffix", "rulePayload": "openai.com"],
            ["metadata": ["host": "api.openai.com"], "chains": ["fixture-exit", "fixture-select"]],
            ["metadata": ["host": "chatgpt.com"], "chains": ["fixture-direct"]],
            ["metadata": ["host": "generativelanguage.googleapis.com"], "chains": ["fixture-gemini"]],
            ["metadata": ["host": "notopenai.com"], "chains": ["fixture-unmatched"]]
        ]])!
        let api = connections.first { $0.name == "OpenAI API" }!
        precondition(api.count == 2 && api.chains == ["fixture-exit → fixture-select"] && api.rules == ["DomainSuffix:openai.com"])
        precondition(connections.first { $0.name == "ChatGPT/Codex" }?.count == 1)
        precondition(connections.first { $0.name == "Gemini" }?.count == 1)
        precondition(NetworkScanner.parseConnections([:]) == nil)
        var first = AIExitStatus(id: "fixture", name: "Fixture AI", host: "example.test")
        var second = first
        second.ip = "192.0.2.1"; second.loc = "US"; second.capturedAt = 1
        precondition(exitChange(previous: first, current: second) == nil)
        first = second
        precondition(exitChange(previous: first, current: second) == nil)
        second.ip = "198.51.100.1"
        precondition(exitChange(previous: first, current: second)?.isCountryChange == false)
        second = first; second.loc = "JP"
        precondition(exitChange(previous: first, current: second)?.isCountryChange == true)
        precondition(AppDelegate.shouldNotifyExit(lastAt: nil, now: 1))
        precondition(!AppDelegate.shouldNotifyExit(lastAt: 1, now: 600))
        precondition(AppDelegate.shouldNotifyExit(lastAt: 1, now: 601))
    }

    do {
        let suite = "vibegauge-selftest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 4)
        defaults.set(2, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 2, "迁移只能执行一次")
    }

    do {
        precondition(UsageHistory.levels([]) == [])
        precondition(UsageHistory.levels([0, 0, -1]) == [0, 0, 0])
        precondition(UsageHistory.levels([0, 1, 2, 3, 4, 5]) == [0, 1, 2, 3, 4, 5])
        precondition(Set(UsageHistory.levels([10, 10, 10])).count == 1)
        let boundary = Fmt.parseISODate("2026-09-18T16:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        precondition(UsageHistory.dayKey(timestamp: boundary, timeZone: zone) == "2026-09-19")
        precondition(UsageHistory.dayKey(timestamp: boundary - 1, timeZone: zone) == "2026-09-18")
        precondition(UsageHistory.dayKey(timestamp: boundary, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-09-18")
        let last = UsageHistory.codexLastTokenUsage(["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10, "reasoning_output_tokens": 2])
        precondition(last.ctx == 100 && last.cacheRead == 40 && last.out == 10 && last.think == 2)
        let delta = UsageHistory.codexCumulativeDelta(previous: ["input_tokens": 100, "output_tokens": 10], current: ["input_tokens": 130, "output_tokens": 15])!
        precondition(delta.ctx == 30 && delta.out == 5)
        precondition(UsageHistory.codexCumulativeDelta(previous: ["input_tokens": 100], current: ["input_tokens": 10]) == nil)
        var prior: [String: Int64]?
        let one: [String: Int64] = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10]
        let two: [String: Int64] = ["input_tokens": 200, "cached_input_tokens": 80, "output_tokens": 20]
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": one], previous: &prior)?.usage.ctx == 100)
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": two], previous: &prior)?.usage.ctx == 100)
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": two], previous: &prior) == nil)
        precondition(UsageHistory.codexUsage(info: [:], previous: &prior) == nil)
        let a = UsageHistory.Record(id: "fixture-request", source: "Claude", timestamp: boundary, model: "fixture-model", usage: last)
        var updated = a; updated.usage.out = 20
        let merged = UsageHistory.deduplicateClaude(["file-a": [a, updated], "file-b": [updated]])
        precondition(merged.count == 1 && merged[a.id]?.usage.out == 20)
        precondition(Fmt.tokens(10_000) == L("1.0 万", "10.0k") && Fmt.tokens(100_000_000) == L("1.00 亿", "100.0M"))
        precondition(Fmt.tokens(2_350_000_000) == L("23.50 亿", "2.35B") && Fmt.tokens(9_999) == "9999")
    }

    // 临时目录覆盖真实增量路径：重启、跨文件去重、追加半行、重写、模型成本重算。
    do {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibegauge-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ relative: String, _ text: String, append: Bool = false) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
            } else { try Data(text.utf8).write(to: url) }
        }
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        func claude(_ id: String, _ ts: String, _ input: Int, _ output: Int, read: Int = 0, cacheWrite: Int = 0) throws -> String {
            try line(["type": "assistant", "timestamp": ts, "requestId": id, "message": ["model": "fixture-priced", "usage": ["input_tokens": input, "cache_read_input_tokens": read, "cache_creation_input_tokens": cacheWrite, "output_tokens": output]]])
        }
        func codex(_ ts: String, total: [String: Int], last: [String: Int]? = nil) throws -> String {
            var info: [String: Any] = ["total_token_usage": total]
            if let last { info["last_token_usage"] = last }
            return try line(["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": info]])
        }
        let before = "2026-09-18T15:59:59Z", after = "2026-09-18T16:00:01Z"
        let ca = ".claude/projects/fixture/a.jsonl", cb = ".claude/projects/fixture/b.jsonl"
        let codexA = ".codex/sessions/2026/09/18/a.jsonl", codexB = ".codex/sessions/2026/09/18/b.jsonl"
        let request = try claude("fixture-1", before, 10, 6, read: 20, cacheWrite: 5)
        try write(ca, try claude("fixture-1", before, 10, 3, read: 20, cacheWrite: 5) + request + claude("fixture-2", after, 10, 4))
        try write(cb, request)
        let u1 = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10]
        let u2 = ["input_tokens": 200, "cached_input_tokens": 80, "output_tokens": 20]
        let u3 = ["input_tokens": 240, "cached_input_tokens": 96, "output_tokens": 24]
        try write(codexA, try line(["type": "turn_context", "payload": ["model": "fixture-priced"]])
                  + codex(before, total: u1, last: u1) + codex(after, total: u2, last: u1)
                  + codex(after, total: u2, last: u1) + codex(after, total: u3)
                  + line(["type": "event_msg", "timestamp": after, "payload": ["type": "token_count", "info": NSNull()]]))
        try write(codexB, try codex(before, total: ["input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 5])
                  + codex(after, total: ["input_tokens": 80, "cached_input_tokens": 16, "output_tokens": 8]))
        try write(".config/vibegauge/api-calls.jsonl", try line(["ts": after, "host": "example.test", "provider": "Fixture A", "model": "fixture-priced", "ctx": 30, "cache_read": 5, "out": 3])
                  + line(["ts": after, "host": "example.test", "provider": "Fixture B", "model": "fixture-unpriced", "ctx": 50, "cache_write": 10, "out": 4]))
        let collector = UsageHistory(home: root.path)
        collector.scanNowForTesting()
        var snap = collector.snapshot()
        precondition(snap.totals["Claude"]?.ctx == 45 && snap.totals["Claude"]?.out == 10 && snap.totals["Claude"]?.turns == 2 && snap.totals["Claude"]?.sessions == 2)
        precondition(snap.totals["Codex"]?.ctx == 320 && snap.totals["Codex"]?.out == 32 && snap.totals["Codex"]?.turns == 5 && snap.totals["Codex"]?.sessions == 2)
        precondition(snap.totals["API · Fixture A"]?.ctx == 30 && snap.totals["API · Fixture B"]?.ctx == 50)
        precondition(snap.cost == nil && !snap.hasPriceTable && snap.error.isEmpty)
        let cacheURL = root.appendingPathComponent(".config/vibegauge/usage-daily.json")
        func checkCachePermissions() throws {
            let file = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
            let dir = try FileManager.default.attributesOfItem(atPath: cacheURL.deletingLastPathComponent().path)
            precondition(file[.posixPermissions] as? Int == 0o600 && dir[.posixPermissions] as? Int == 0o700)
        }
        try checkCachePermissions()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cacheURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.deletingLastPathComponent().path)
        // 保存有节流，重启实例并追加空行才能触发真实写入，同时保持统计结果不变。
        try write(ca, "\n", append: true)
        UsageHistory(home: root.path).scanNowForTesting()
        try checkCachePermissions()
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        let states = disk["files"] as! [String: [String: Any]]
        let codexSize = try Data(contentsOf: root.appendingPathComponent(codexA)).count
        let codexStates = states.filter { $0.key.hasSuffix("/" + codexA) }
        precondition(codexStates.count == 1 && (codexStates.first?.value["offset"] as? NSNumber)?.intValue == codexSize)
        // 人工测试价目表只作用于临时目录中的 fixture 模型，不提供任何生产默认价格。
        try write(".config/vibegauge/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 1, "cache_read": 2, "cache_write": 3, "out": 4]]))
        collector.scanNowForTesting(); snap = collector.snapshot()
        precondition(abs((snap.cost ?? -1) - 0.000594) < 1e-10 && snap.unpricedModels == 2)
        try write(".config/vibegauge/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 2, "cache_read": 4, "cache_write": 6, "out": 8]]))
        collector.scanNowForTesting()
        precondition(abs((collector.snapshot().cost ?? -1) - 0.001188) < 1e-10)
        let added = try claude("fixture-3", after, 7, 1)
        let split = added.index(added.startIndex, offsetBy: added.count / 2)
        try write(ca, String(added[..<split]), append: true)
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals["Claude"]?.turns == 2, "半行不能提前计入")
        try write(ca, String(added[split...]), append: true)
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals["Claude"]?.turns == 3)
        try write(cb, try claude("fixture-4", after, 10, 2))
        try write(ca, try claude("fixture-5", after, 3, 1))
        collector.scanNowForTesting(); snap = collector.snapshot()
        precondition(snap.totals["Claude"]?.turns == 2 && snap.totals["Claude"]?.ctx == 13, "重写必须撤销旧文件贡献")
        let restarted = UsageHistory(home: root.path)
        restarted.scanNowForTesting()
        precondition(restarted.snapshot().totals == snap.totals && restarted.snapshot().error.isEmpty)
    } catch { preconditionFailure("统计临时日志自测失败：\(error)") }

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
        for o in r.orphans { print(String(format: "  pid %-7d %5.0f MB  %@", o.pid, o.memMB, String(o.cmd.prefix(90)))) }
        print(L("--- 规则放过的（原因）---", "--- Protected by rules (reason) ---"))
        for p in r.protected { print(String(format: "  pid %-7d %5.0f MB  [%@]  %@", p.pid, p.memMB, p.reason, String(p.cmd.prefix(70)))) }
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
        let secondaryPool = l.secondaryPoolName == "三方" ? L("三方", "Third-party") : l.secondaryPoolName
        print("\(l.isRunning ? "●" : "○") \(l.name) [\(l.tier)] \(l.detail)" + w("5H", l.fiveHour) + w("W", l.sevenDay, profile) + w("\(secondaryPool)5H", l.secondaryFiveHour) + w("\(secondaryPool)W", l.secondarySevenDay, profile) + (l.hasQuota ? "" : "  | \(l.quotaSubtitle)"))
    }
    let rs = ProcessScanner.shared.codexRemoteStatus()
    print(L("Codex 远程 \(rs.host): \(rs.ok ? "已连上" : "未连上") · \(rs.ageSeconds)s 前拉取", "Codex remote \(rs.host): \(rs.ok ? "connected" : "not connected") · fetched \(rs.ageSeconds)s ago"))
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
    var progressAt = Date.distantPast
    while UsageHistory.shared.snapshot().capturedAt == 0 || NetworkScanner.shared.snapshot().capturedAt == 0 {
        precondition(Date() < historyDeadline, "后台首次采集超时，不能把未完成汇总标为通过")
        if Date().timeIntervalSince(progressAt) > 15 {
            let progress = UsageHistory.shared.snapshot()
            print(L("历史汇总进度：\(progress.processedFiles)/\(progress.totalFiles) 文件", "History progress: \(progress.processedFiles)/\(progress.totalFiles) files"))
            progressAt = Date()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    func maskedIP(_ ip: String) -> String {
        if ip.contains(":") { return ip.split(separator: ":").prefix(2).joined(separator: ":") + ":x:x" }
        let parts = ip.split(separator: ".")
        return parts.count == 4 ? parts.prefix(2).joined(separator: ".") + ".x.x" : L("查不到", "Unavailable")
    }
    precondition(maskedIP("192.0.2.7") == "192.0.x.x")
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
    print(L("新增纯函数、Tab 迁移和增量缓存自测通过", "Pure functions, tab migration, and incremental cache self-tests passed"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
