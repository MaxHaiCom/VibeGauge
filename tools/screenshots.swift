// README 截图：用虚构的演示数据离屏渲染面板（不截屏、不读本机任何真实用量）。
// 用法：tools/screenshots.sh   → assets/screenshots/{zh,en}-{plans,forecast,network,stats,mac}.png
import AppKit
import SwiftUI

@main
struct Screenshots {
    static let now = Date().timeIntervalSince1970

    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/screenshots"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            for lang in ["zh", "en"] {
                UserDefaults.standard.set(lang, forKey: "uiLanguage")
                for (name, tab, drill) in [("plans", 0, nil), ("forecast", 0, "Claude"), ("network", 3, nil), ("stats", 2, nil), ("mac", 4, nil)] as [(String, Int, String?)] {
                    UserDefaults.standard.set(tab, forKey: "vg.tab")
                    render(DashboardView(demo: report(), history: history(), network: network(), drillDown: drill),
                           to: "\(out)/\(lang)-\(name).png")
                }
            }
            for k in ["uiLanguage", "vg.tab"] { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    @MainActor static func render(_ view: DashboardView, to path: String) {
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        for _ in 0..<3 {                                   // SwiftUI 量高度要跑几轮布局
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            win.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        let scale: CGFloat = 2, w = Int(host.bounds.width * scale), h = Int(host.bounds.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 菜单面板的圆角与底色
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(red: 0.118, green: 0.118, blue: 0.13, alpha: 1))
        ctx.fill(rect)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
    }

    static func win(_ used: Int, resetIn: Double, window: Double, recent: Double = 0, last: Int? = nil) -> QuotaWindow {
        var w = QuotaWindow(usedPct: used, resetsAt: now + resetIn, capturedAt: now - 20, windowSeconds: window)
        if recent > 0 { w.recentPctPerHour = recent; w.recentSpanMinutes = 40 }
        w.lastCyclePct = last
        return w
    }

    static let hour = 3600.0, day = 86400.0, fiveH = 5 * 3600.0, week = 7 * 86400.0

    // MARK: 扫描报告（订阅 / 系统页）

    static func report() -> ScanReport {
        var r = ScanReport()
        r.totalMemoryGB = 32; r.usedMemoryGB = 13.4; r.freePercentage = 58; r.swapUsedGB = 0.4; r.compressorGB = 2.1
        r.loadAvg1m = 3.2; r.loadAvg5m = 3.6
        r.diskTotalGB = 994; r.diskFreeGB = 412; r.diskFreePct = 41
        r.activeMCPProcessCount = 46; r.activeMCPTotalMemMB = 1900; r.npxCacheMB = 410
        r.orphanedGroups = [ServiceGroup(serviceName: L("Chrome DevTools 自动化插件", "Chrome DevTools automation"), processCount: 3, totalMemMB: 186, pids: [5101, 5102, 5103])]
        r.totalOrphanCount = 3; r.totalOrphanMemMB = 186
        r.disk = [
            DiskItem(path: "~/.codex/sessions", label: L("Codex 会话记录", "Codex sessions"), totalMB: 2140, files: 910, oldMB: 1380, oldFiles: 620, purgeable: true,
                     note: L("删掉就不能 --resume 这些旧会话", "Deleting prevents --resume for these sessions")),
            DiskItem(path: "~/.claude/projects", label: L("Claude 会话记录", "Claude sessions"), totalMB: 1310, files: 1200, oldMB: 240, oldFiles: 300, purgeable: true,
                     note: L("删掉就不能 --resume / --continue 这些旧会话", "Deleting prevents --resume / --continue for these sessions")),
            DiskItem(path: "~/.codex/logs", label: L("Codex 日志库", "Codex log database"), totalMB: 420, purgeable: false,
                     note: L("运行时数据库，删了会弄坏 Codex", "Runtime database; deleting breaks Codex")),
            DiskItem(path: "~/.claude/plugins", label: L("Claude 插件", "Claude plugins"), totalMB: 210, purgeable: false,
                     note: L("装上的东西，不是缓存", "Installed content, not a cache")),
        ]
        r.diskTotalAIGB = 6.4

        let claude = DetectedLLMRuntime(
            name: "Claude", isRunning: true, tier: "Max 5x", detail: L("3 会话", "3 sessions"),
            fiveHour: win(34, resetIn: 2 * hour + 40 * 60, window: fiveH, recent: 9),
            sevenDay: win(58, resetIn: 3 * day + 6 * hour, window: week, last: 81),
            platformDetail: PlatformDetail(
                rows: [(L("订阅", "Subscription"), "Max 5x"), (L("额度来源", "Quota source"), L("状态栏官方额度（已连接）", "Official status-line quota (connected)"))],
                sessions: [SessionInfo(pid: 4101, cwd: "~/code/my-app", startedAgo: 5400, memMB: 310),
                           SessionInfo(pid: 4188, cwd: "~/code/api-server", startedAgo: 1900, memMB: 280),
                           SessionInfo(pid: 4230, cwd: "~/notes", startedAgo: 600, memMB: 190)],
                sourceFiles: ["~/.claude.json", "~/.config/vibegauge/claude-usage.json", "~/.claude/projects/*.jsonl"]))
        let codex = DetectedLLMRuntime(
            name: "Codex", isRunning: true, tier: "Pro", detail: L("1 会话", "1 session"),
            fiveHour: win(12, resetIn: 4 * hour + 10 * 60, window: fiveH),
            sevenDay: win(41, resetIn: 4 * day + 2 * hour, window: week, last: 63))
        let gemini = DetectedLLMRuntime(
            name: "Gemini", isRunning: true, tier: "AI Pro", detail: L("1 会话", "1 session"),
            fiveHour: win(22, resetIn: 3 * hour, window: fiveH), sevenDay: win(35, resetIn: 5 * day, window: week),
            secondaryPoolName: "三方", secondaryFiveHour: win(8, resetIn: 4 * hour, window: fiveH),
            secondarySevenDay: win(14, resetIn: 5 * day + 13 * hour, window: week), isFullWidth: true)
        let grok = DetectedLLMRuntime(
            name: "Grok", isRunning: false, tier: "SuperGrok", detail: L("0 会话", "0 sessions"),
            sevenDay: win(18, resetIn: 2 * day + 5 * hour, window: week))
        r.detectedLLMs = [claude, codex, gemini, grok]

        var t = TokenStats()
        t.todayTurns = 412; t.todayContext = 86_400_000; t.todayCacheRead = 83_900_000
        t.todayOutput = 512_000; t.todayThinking = 148_000
        t.todayByProject = [
            ProjectUsage(path: "~/code/my-app", turns: 188, ctx: 41_200_000, out: 238_000, think: 71_000, clis: ["Claude"]),
            ProjectUsage(path: "~/code/api-server", turns: 121, ctx: 26_900_000, out: 160_000, think: 44_000, clis: ["Claude", "Codex"]),
            ProjectUsage(path: "~/code/landing-page", turns: 64, ctx: 12_100_000, out: 79_000, think: 21_000, clis: ["Codex"]),
            ProjectUsage(path: "~/notes", turns: 39, ctx: 6_200_000, out: 35_000, think: 12_000, clis: ["Claude"]),
        ]
        t.recentInteractions = [
            InteractionRecord(id: "a", model: "claude-opus-5", timestamp: now - 40, contextTokens: 612_000, cacheReadTokens: 609_800, outputTokens: 3_812, thinkingTokens: 1_904),
            InteractionRecord(id: "b", model: "claude-opus-5", timestamp: now - 190, contextTokens: 604_000, cacheReadTokens: 601_900, outputTokens: 1_120, thinkingTokens: 0),
            InteractionRecord(id: "c", model: "claude-opus-5", timestamp: now - 320, contextTokens: 598_000, cacheReadTokens: 595_100, outputTokens: 2_408, thinkingTokens: 870),
        ]
        r.tokens = t
        r.cliUsage = [
            CLIUsage(name: "Codex", requests: 96, ctx: 18_300_000, cacheRead: 16_900_000, out: 142_000, think: 51_000, turns: 96),
            CLIUsage(name: "Grok", turns: 11, note: L("本地无 token 统计，仅轮次", "No local token stats; turns only")),
        ]
        return r
    }

    // MARK: 历史（统计页 + 作息画像）

    static func history() -> UsageHistory.Snapshot {
        var s = UsageHistory.Snapshot()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        var totalC = UsageHistory.Totals(), totalX = UsageHistory.Totals()
        for i in (0..<42).reversed() {
            let date = Date(timeIntervalSince1970: now - Double(i) * day)
            let weekday = cal.component(.weekday, from: date)
            let wave = 0.55 + 0.45 * sin(Double(i) * 0.9) * sin(Double(i) * 0.23 + 1)
            let scale = (weekday == 1 || weekday == 7) ? 0.25 : 1.0
            let ctxC = Int64(160_000_000 * max(0.08, wave) * scale), ctxX = Int64(38_000_000 * max(0.05, 1 - wave) * scale)
            func totals(_ ctx: Int64, _ model: String) -> UsageHistory.Totals {
                let m = UsageHistory.ModelTotals(ctx: ctx, cacheRead: ctx * 96 / 100, cacheWrite: ctx / 50, out: ctx / 170, think: ctx / 600)
                return UsageHistory.Totals(ctx: m.ctx, cacheRead: m.cacheRead, cacheWrite: m.cacheWrite, out: m.out, think: m.think,
                                           turns: Int(ctx / 210_000), sessions: max(1, Int(ctx / 25_000_000)), models: [model: m])
            }
            let c = totals(ctxC, "claude-opus-5"), x = totals(ctxX, "gpt-6")
            let key = UsageHistory.dayKey(timestamp: date.timeIntervalSince1970)
            s.days.append(UsageHistory.Day(date: key, sources: ["Claude": c, "Codex": x]))
            s.dailyTokens[key] = c.tokenTotal + x.tokenTotal
            totalC.merge(c); totalX.merge(x)
        }
        totalC.sessions = 386; totalX.sessions = 142            // merge 不累加会话数（真实数据按日志文件数另算）
        s.totals = ["Claude": totalC, "Codex": totalX]
        s.aggregate.merge(totalC); s.aggregate.merge(totalX)
        s.earliestDate = s.days.first?.date
        s.activeDays = s.dailyTokens.values.filter { $0 > 0 }.count
        s.hasPriceTable = true; s.priceCurrency = "USD"
        s.costBySource = ["Claude": 1_842.6, "Codex": 391.2]; s.cost = 2_233.8
        s.capturedAt = now; s.processedFiles = 2_410; s.totalFiles = 2_410
        // 作息：9–12、13–19、21–24 点在用，凌晨睡觉
        var hours = [Double](repeating: 0, count: 24)
        for h in 9...11 { hours[h] = 60 }
        for h in 13...18 { hours[h] = 80 }
        for h in 21...23 { hours[h] = 45 }
        hours[0] = 12; hours[12] = 15; hours[19] = 20; hours[20] = 18
        s.hourCounts = ["Claude": hours, "Codex": hours.map { $0 * 0.4 }, "*": hours]
        return s
    }

    // MARK: 网络页（IP 全部用文档保留网段 203.0.113.0/24、198.51.100.0/24）

    static func network() -> NetworkSnapshot {
        var n = NetworkSnapshot()
        n.aiExits = [("claude", "Claude", "api.anthropic.com", 182), ("chatgpt", "ChatGPT/Codex", "chatgpt.com", 176),
                     ("openai", "OpenAI API", "api.openai.com", 171), ("grok", "Grok", "grok.com", 190)].map { id, name, host, ms in
            var e = AIExitStatus(id: id, name: name, host: host)
            e.ip = "203.0.113.24"; e.loc = "US"; e.colo = "SJC"; e.latencyMS = ms; e.attemptedAt = now - 30; e.capturedAt = now - 30
            return e
        }
        var g = AIExitStatus(id: "gemini", name: "Gemini", host: "generativelanguage.googleapis.com", isGemini: true)
        g.error = L("走出站：", "Egress: ") + "AI → US-West-01"; g.capturedAt = now - 30
        n.aiExits.append(g)
        n.proxy.running = true; n.proxy.version = "mihomo 1.19"
        n.proxy.groups = [ProxyGroupStatus(name: "AI", type: "Selector", now: "US-West-01"),
                          ProxyGroupStatus(name: "Proxy", type: "URLTest", now: "JP-Tokyo-02")]
        n.proxy.connections = [AIConnectionStatus(name: "Gemini", count: 4, chains: ["AI → US-West-01"], rules: ["DOMAIN-SUFFIX,googleapis.com"])]
        n.local.gateway = "192.168.1.1"; n.local.interfaceName = "en0"; n.local.ipv4 = "192.168.1.23"
        n.local.dnsServers = ["198.18.0.2"]; n.local.wifiName = "Home-WiFi"
        n.local.uploadBPS = 186_000; n.local.downloadBPS = 2_450_000; n.local.capturedAt = now
        n.leak.ipv6Blocked = true; n.leak.ipv6Message = L("IPv6 出站已阻断 ✓", "IPv6 egress blocked ✓")
        n.leak.dnsVerdict = .proxyOK; n.leak.checkedAt = now - 30
        n.capturedAt = now
        return n
    }
}
