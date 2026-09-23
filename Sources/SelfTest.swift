import Cocoa

// `--selftest`：离线确定性测试。只用临时目录和内置 fixture，不读本机真实日志、不联网，CI 必跑。
// 新逻辑配一条 precondition：逻辑坏了它就失败。
enum SelfTest {
    static func run() {
        precondition(Fmt.modelDisplayName("claude-fable-5-1") == "Fable 5.1")
        precondition(Fmt.modelDisplayName("claude-opus-5") == "Opus 5")
        precondition(Fmt.modelDisplayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        precondition(Fmt.modelDisplayName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
        precondition(Fmt.modelDisplayName("gpt-6-astra") == "gpt-6-astra" && Fmt.modelDisplayName("deepseek-v4-flash-ga-260731") == "deepseek-v4-flash-ga-260731")
        precondition(Fmt.modelDisplayName("models/gemini-3.8-flash") == "gemini-3.8-flash" && Fmt.modelDisplayName("anthropic/claude-opus-5") == "Opus 5")
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

        precondition(ProcessScanner.memoryPressurePageSize("The system has 8589934592 (2097152 pages with a page size of 4096).") == 4096, "Intel 4KB 页")
        precondition(ProcessScanner.memoryPressurePageSize("The system has 25769803776 (1572864 pages with a page size of 16384).") == 16384)
        precondition(ProcessScanner.memoryPressurePageSize("garbage") == nil)
        precondition(Diagnostics.maskedIP("192.0.2.7") == "192.0.x.x" && Diagnostics.maskedIP("2001:db8::1") == "2001:db8:x:x")
        // API 卡片身份：同一上游路由只有一个 key 不拆；两个 key 按账户拆；同 host 不同路由（火山 Coding / 按量）永远分开
        do {
            func call(_ host: String, _ provider: String, _ key: String) -> ProcessScanner.APICall {
                ProcessScanner.APICall(ts: 1, host: host, provider: provider, model: "m", ctx: 0, cacheRead: 0, cacheWrite: 0, out: 0, think: 0, status: 200, ms: 1, key: key, rl: [:])
            }
            let calls = [call("a.test", "A", "k1"), call("a.test", "A", "k1"), call("b.test", "B", "k1"), call("b.test", "B", "k2"), call("b.test", "B", ""),
                         call("v.test", "V Coding", "k1"), call("v.test", "V 按量", "k1")]
            let split = ProcessScanner.splitGroups(calls)
            precondition(split == ["b.test|B"], "拆卡：\(split)")
            // ID 总带指纹（拆不拆只影响标题）：后来多出一个 key，已有卡的 ID 不跳变
            let ids = Set(calls.map { ProcessScanner.cardID(host: $0.host, provider: $0.provider, key: $0.key) })
            precondition(ids == ["a.test|A#k1", "b.test|B#k1", "b.test|B#k2", "b.test|B#-", "v.test|V Coding#k1", "v.test|V 按量#k1"], "卡片 ID：\(ids.sorted())")
            var one = APIProviderStatus(host: "b.test", provider: "B"); one.account = "abcd0001"; one.showsAccount = true
            var two = one; two.account = "abcd0002"
            precondition(one.displayName != two.displayName, "标题前缀要能区分：\(one.displayName)")
        }
        // 滚动窗口：过了「下一笔释放」不归零、不做到期预测、不按释放时刻分通知周期
        do {
            let t: TimeInterval = 1_790_000_000
            let w = ProcessScanner.rollingWindow([t - 4 * 3600, t - 4 * 3600 + 30, t - 3600, t - 6 * 3600], seconds: 5 * 3600, limit: 10, now: t)!
            precondition(w.isRolling && w.usedPct == 30 && w.resetsAt == t + 3600 && w.releaseCount == 2, "滚动窗口：\(w)")
            precondition(!w.isExpired(now: t + 7200) && w.effectivePct(now: t + 7200) == 30 && w.burn(now: t) == nil)
            precondition(w.resetText(now: t) == L("1h0m 后释放 2 次", "frees 2 in 1h0m"), w.resetText(now: t) ?? "nil")
            precondition(w.resetText(now: t + 3601) == L("待刷新", "refreshing") && w.shortResetText(now: t + 3601) == L("待刷新", "refreshing"))
            var r = ScanReport(); var p = APIProviderStatus(host: "h", provider: "P"); p.fiveHour = w; r.api.providers = [p]
            var later = r; later.api.providers[0].fiveHour?.resetsAt = t + 3700
            precondition(r.pressures.first { $0.kind == .quota }?.key == later.pressures.first { $0.kind == .quota }?.key, "滚动窗口通知键不能随释放时刻变")
        }
        // 本机模型服务识别：App 包路径带空格、独立版 llmster、MLX / llama.cpp 端口；grep / cat 之类不算
        do {
            let lm = "lm studio.app/", lmBins = ["lm studio", "lmstudio", "llmster"]
            precondition(ProcessScanner.isRunning("/Applications/LM Studio.app/Contents/MacOS/LM Studio --type=renderer", bundle: lm, bins: lmBins))
            precondition(ProcessScanner.isRunning("/Users/x/.lmstudio/bin/llmster --port 1234", bundle: lm, bins: lmBins))
            precondition(!ProcessScanner.isRunning("/usr/bin/grep -r /Applications/LM Studio.app/Contents", bundle: lm, bins: lmBins))
            precondition(!ProcessScanner.isRunning("/bin/cat /Applications/LM Studio.app/x", bundle: lm, bins: lmBins))
            precondition(!ProcessScanner.isRunning("/bin/zsh -c open /Applications/LM Studio.app", bundle: lm, bins: lmBins))
            precondition(ProcessScanner.isMLXServer("/opt/homebrew/bin/python3.12 -m mlx_lm.server --model m --port 9000"))
            precondition(ProcessScanner.isMLXServer("/Users/x/.venv/bin/mlx_lm.server --model m"))
            precondition(!ProcessScanner.isMLXServer("/bin/zsh -c python3 -m mlx_lm.server") && !ProcessScanner.isMLXServer("/usr/bin/grep mlx_lm.server"))
            precondition(ProcessScanner.portArg("llama-server -m x.gguf --port 8081") == 8081 && ProcessScanner.portArg("x --port=9000") == 9000 && ProcessScanner.portArg("x") == nil)
            let unparsed = ProcessScanner.shared.parseAPICallLine(#"{"epoch":1790000000,"host":"h","provider":"P","status":200,"complete":true,"parsed":false,"error":"usage_not_found"}"#)
            precondition(unparsed?.parsed == false && unparsed?.failed == false, "成功但无用量的调用要能分出来")
            precondition(ProcessScanner.shared.parseAPICallLine(#"{"epoch":1790000000,"host":"h","status":200}"#)?.parsed == true, "旧记录缺 parsed 当已解析")
        }
        // 数据可信状态：过重置点 = 等待新回报（不是 0%）；超过窗口 1/5 没更新 = 可能过期；滚动窗口 = 估算
        do {
            let t: TimeInterval = 1_790_000_000
            func w(reset: TimeInterval, captured: TimeInterval, seconds: Double = 5 * 3600) -> QuotaWindow {
                QuotaWindow(usedPct: 40, resetsAt: reset, capturedAt: captured, windowSeconds: seconds)
            }
            precondition(w(reset: t + 3600, captured: t - 60).trust(now: t) == .reported)
            precondition(w(reset: t + 3600, captured: t - 3601).trust(now: t) == .stale)
            precondition(w(reset: t + 86400, captured: t - 86400, seconds: 7 * 86400).trust(now: t) == .reported, "周窗口一天前的数据不算过期")
            precondition(w(reset: t - 1, captured: t - 60).trust(now: t) == .awaiting)
            var r = w(reset: t + 3600, captured: t); r.isRolling = true
            precondition(r.trust(now: t) == .estimated)
            precondition(w(reset: t - 1, captured: t - 60).trustText(now: t) == L("等待新回报", "Awaiting update"))
        }
        // 预计打满提醒：只报官方回报的窗口；预测持续 15 分钟才发；同一周期只发一次；预测消失再出现要重新计时
        do {
            let t: TimeInterval = 1_790_000_000
            var hot = QuotaWindow(usedPct: 80, resetsAt: t + 7200, capturedAt: t, windowSeconds: 5 * 3600)
            hot.recentPctPerHour = 30; hot.recentSpanMinutes = 30          // 40 分钟打满，早于 2 小时后的重置
            var calm = hot; calm.recentPctPerHour = 1
            var stale = hot; stale.capturedAt = t - 3 * 3600
            var rolling = hot; rolling.isRolling = true
            let found = ForecastCandidate.find(in: [("Claude", "5h", hot, nil), ("Codex", "5h", calm, nil), ("Grok", "5h", stale, nil), ("API", "5h", rolling, nil), ("X", "5h", nil, nil)], now: t)
            precondition(found.map(\.key) == ["forecast:Claude:5h@\(Int(t + 7200))"], "候选：\(found.map(\.key))")
            precondition(abs((found.first?.exhaustAt ?? 0) - (t + 2400)) < 1)
            var seen: [String: TimeInterval] = [:]
            precondition(AppDelegate.dueForecasts(found, firstSeen: &seen, notified: [], now: t).isEmpty, "刚出现不报")
            precondition(AppDelegate.dueForecasts(found, firstSeen: &seen, notified: [], now: t + 600).isEmpty)
            precondition(AppDelegate.dueForecasts(found, firstSeen: &seen, notified: [], now: t + 900).count == 1, "持续 15 分钟后报")
            precondition(AppDelegate.dueForecasts(found, firstSeen: &seen, notified: [found[0].key], now: t + 1000).isEmpty, "同周期不重报")
            _ = AppDelegate.dueForecasts([], firstSeen: &seen, notified: [], now: t + 1100)
            precondition(AppDelegate.dueForecasts(found, firstSeen: &seen, notified: [], now: t + 1200).isEmpty, "预测消失后重新计时")
        }
        // 今日模型构成：跨 CLI 来源同名合并、不含经代理的 API、按 token 降序
        do {
            func totals(_ models: [String: (Int64, Int64)]) -> UsageHistory.Totals {
                var t = UsageHistory.Totals()
                for (m, v) in models { t.models[m] = UsageHistory.ModelTotals(ctx: v.0, out: v.1) }
                return t
            }
            let day = UsageHistory.Day(date: "2026-09-23", sources: ["Claude": totals(["claude-opus-5": (100, 10), "shared": (5, 0)]),
                                                                  "Codex": totals(["gpt-6-astra": (300, 20), "shared": (5, 0)]),
                                                                  "API · GLM": totals(["glm-5": (999, 9)])])
            let mix = UsageHistory.modelMix(day)
            precondition(mix.map(\.model) == ["gpt-6-astra", "claude-opus-5", "shared"] && mix[2].usage.ctx == 10, "模型构成：\(mix)")
            precondition(UsageHistory.modelMix(nil).isEmpty)
        }
        precondition(ProxyManager.validPort(0) == 18790 && ProxyManager.validPort(80) == 18790 && ProxyManager.validPort(18791) == 18791 && ProxyManager.validPort(70000) == 18790)

        // Codex 跨零点：total_token_usage 是会话累计，今天只算零点后新增的；请求数只数今天的事件
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vg-codex-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            func ev(_ t: TimeInterval, _ input: Int, _ out: Int) -> String {
                #"{"timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: t)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(out),"reasoning_output_tokens":0}}}}"#
            }
            let meta = #"{"timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: midnight - 3600)))","type":"session_meta","payload":{}}"#
            let resumed = tmp.appendingPathComponent("resumed.jsonl")
            try? ([meta, ev(midnight - 1800, 100, 10), ev(midnight + 600, 130, 14), ""].joined(separator: "\n")).write(to: resumed, atomically: true, encoding: .utf8)
            let r = ProcessScanner.shared.codexFileUsage(path: resumed.path, startOfToday: midnight)!
            precondition(r.ctx == 30 && r.out == 4 && r.requests == 1, "跨零点只算今天：\(r.ctx)/\(r.out)/\(r.requests)")
            let fresh = tmp.appendingPathComponent("fresh.jsonl")
            try? ([ev(midnight + 60, 50, 5), ev(midnight + 120, 80, 9), ""].joined(separator: "\n")).write(to: fresh, atomically: true, encoding: .utf8)
            let f = ProcessScanner.shared.codexFileUsage(path: fresh.path, startOfToday: midnight)!
            precondition(f.ctx == 80 && f.out == 9 && f.requests == 2, "今天才开始的会话：全算")
            // 首行超过 4KB（读不出开始时间）也要找到零点前基线；重复写入的同一份快照不算新请求
            let bigMeta = #"{"timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: midnight - 3600)))","type":"session_meta","payload":{"instructions":"\#(String(repeating: "x", count: 6000))"}}"#
            let big = tmp.appendingPathComponent("big.jsonl")
            try? ([bigMeta, ev(midnight - 1800, 100, 10), ev(midnight + 600, 130, 14), ev(midnight + 601, 130, 14), ""].joined(separator: "\n")).write(to: big, atomically: true, encoding: .utf8)
            let b = ProcessScanner.shared.codexFileUsage(path: big.path, startOfToday: midnight)!
            precondition(b.ctx == 30 && b.requests == 1, "大首行 + 重复快照：\(b.ctx)/\(b.requests)")
        }

        // 命令行脱敏：自测输出会被贴进公开 Issue
        precondition(ProcessScanner.redactCommand("node srv.js --api-key sk-abc123 --port 3000") == "node srv.js --api-key *** --port 3000")
        precondition(ProcessScanner.redactCommand("python x.py --token=abcd TOKEN_X=1") == "python x.py --token=*** TOKEN_X=***")
        precondition(ProcessScanner.redactCommand("curl https://me:pw@host.example/api") == "curl https://***@host.example/api")
        precondition(ProcessScanner.redactCommand("run sk-ant-FAKEabcdefgh ghp_FAKE12345678") == "run *** ***")
        precondition(ProcessScanner.redactCommand("curl -H Authorization: Bearer abc.def https://x") == "curl -H Authorization: *** *** https://x")
        precondition(ProcessScanner.redactCommand("node a.js --header Authorization:Bearer_abc") == "node a.js --header Authorization:***")
        precondition(ProcessScanner.redactCommand("curl -H x-api-key: abc123 https://x") == "curl -H x-api-key: *** https://x")
        precondition(ProcessScanner.redactCommand("node /users/x/.npm/_npx/ab/mcp-server.js") == "node /users/x/.npm/_npx/ab/mcp-server.js", "普通路径不动")
        precondition(ProcessScanner.parseBaseURLLine("export OPENAI_BASE_URL=https://me:pw@api.example.com/v1", proxyPrefix: "http://127.0.0.1:18790/")?.host == "api.example.com")

        // MCP 判定：只在 _npx 里的普通后台工具不算（以前会被当孤儿杀）；官方 @modelcontextprotocol 包要认
        precondition(!ProcessScanner.isMCPServerCommand("node /users/x/.npm/_npx/ab12/node_modules/.bin/vite build --watch"))
        precondition(!ProcessScanner.isMCPServerCommand("python -m uvicorn app:main"))
        precondition(ProcessScanner.isMCPServerCommand("node /users/x/.npm/_npx/ab12/node_modules/@modelcontextprotocol/server-memory/dist/index.js"))
        precondition(!ProcessScanner.isMCPServerCommand("node /users/x/app/node_modules/@modelcontextprotocol/sdk/dist/client/index.js"), "SDK 客户端不是 MCP 服务")
        precondition(ProcessScanner.isMCPServerCommand("npm exec chrome-devtools-mcp@latest"))
        precondition(ProcessScanner.isMCPServerCommand("node /users/x/lib/context7/index.js", serviceKeys: ["context7"]))

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

        // 阈值通知：警告升危急立刻报；从 0 重新越线 4 小时内只报一次
        precondition(AppDelegate.shouldNotify(level: 2, lastLevel: 1, lastAt: now - 60, now: now), "升到危急不受冷却")
        precondition(!AppDelegate.shouldNotify(level: 1, lastLevel: 0, lastAt: now - 3600, now: now), "抖回来又越线：冷却中")
        precondition(AppDelegate.shouldNotify(level: 2, lastLevel: 0, lastAt: now - 3600, now: now), "90%→70%→97%：危急不受冷却")
        precondition(AppDelegate.shouldNotify(level: 1, lastLevel: 0, lastAt: now - 5 * 3600, now: now))
        precondition(!AppDelegate.shouldNotify(level: 1, lastLevel: 1, lastAt: 0, now: now))
        do {
            var s = ScanReport()
            s.totalMemoryGB = 64; s.freePercentage = 50
            s.diskTotalGB = 1000; s.diskFreeGB = 30; s.diskFreePct = 3                 // 磁盘 97%：危急
            s.detectedLLMs = [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "",
                                                 sevenDay: QuotaWindow(usedPct: 90, resetsAt: now + 86400, capturedAt: now))]   // 90%：警告
            precondition(s.tightest?.short == L("磁盘", "Disk") && s.tightest?.level == 2, "危急排在警告前面：\(String(describing: s.tightest))")
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
            // 最后一次观测离重置 2 天：那不是终值，不当先验
            precondition(ProcessScanner.finishedCycle(["Codex|w@500000": [(t: 500000.0 - 2 * 86400, pct: 40)]], rawKey: "Codex|w", now: 600000) == nil)
            // 最近一小时确实没用（近期速度 0）：5h 按 0 外推，不退回窗口平均
            var idle = QuotaWindow(usedPct: 40, resetsAt: now + 2 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
            idle.recentPctPerHour = 0; idle.recentSpanMinutes = 50
            precondition(idle.burn(now: now)?.projectedAtReset == 40 && idle.burn(now: now)?.isRecent == true)
            // 合盖一晚跨过周重置：一次归档把周和 5h 的终值都存下，之后清掉过期样本也不丢
            var all = samples
            ProcessScanner.archiveFinals(&all, now: 1500)
            precondition(all["final2|Claude|w"]?.last?.pct == 72 && all["final2|Claude|5h"]?.last?.pct == 99)
            precondition(all["final2|Claude|w"]?.last?.t == 1000)
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
            precondition(ipv6Verdict(traceIP: "149.119.151.8", httpStatus: 200).blocked == true)  // IPv4 映射：走隧道，不是泄漏
            precondition(ipv6Verdict(traceIP: "240e:390::1", httpStatus: 200).blocked == false)
            precondition(ipv6Verdict(traceIP: nil, httpStatus: 0, curlExit: 7).blocked == true, "IPv4 通、IPv6 连不上 = 被挡住")
            precondition(ipv6Verdict(traceIP: nil, httpStatus: 0, curlExit: 28).blocked == true)
            precondition(ipv6Verdict(traceIP: nil, httpStatus: 0, curlExit: 60, curlError: "SSL certificate problem").blocked == nil, "证书错误不是阻断")
            precondition(ipv6Verdict(traceIP: nil, httpStatus: 0, curlExit: 7, ipv4Reachable: false).blocked == nil, "断网不能显示成检查通过")
            precondition(ipv6Verdict(traceIP: nil, httpStatus: 200).blocked == false)
            precondition(dnsVerdict([]) == .unknown)
            precondition(dnsVerdict(["192.0.2.1"]) == .unknown)
            precondition(dnsVerdict(["198.18.0.1"]) == .proxyOK)
            precondition(dnsVerdict(["127.0.0.1"]) == .unknown, "本机解析器可能转发给运营商：判断不了")
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
            precondition(Fmt.tokens(18_300_000) == L("1830 万", "18.3M"), "上千万不带小数，窄列里才不折行")
            precondition(Fmt.tokens(142_000) == L("14.2 万", "142k"))
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
            // 样本在 9-18，时钟钉在 9-19：不随真实日期越过 8 天折叠线
            let fixedNow = Fmt.parseISODate("2026-09-19T00:00:00Z")!
            func history() -> UsageHistory { let h = UsageHistory(home: root.path); h.clock = { fixedNow }; return h }
            let collector = history()
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
            history().scanNowForTesting()
            try checkCachePermissions()
            let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
            let states = disk["files"] as! [String: [String: Any]]
            let codexSize = try Data(contentsOf: root.appendingPathComponent(codexA)).count
            let codexStates = states.filter { $0.key.hasSuffix("/" + codexA) }
            precondition(codexStates.count == 1 && (codexStates.first?.value["offset"] as? NSNumber)?.intValue == codexSize)
            // 人工测试价目表只作用于临时目录中的 fixture 模型，不提供任何生产默认价格。
            try write(".config/vibegauge/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 1, "cache_read": 2, "cache_write": 3, "out": 4]]))
            collector.scanNowForTesting(); snap = collector.snapshot()
            // 总成本不含经代理的来源（同一请求已在 CLI 日志里），代理来源仍单独计价
            let apiCost = snap.costBySource.filter { UsageHistory.isProxySource($0.key) }.values.reduce(0, +)
            precondition(apiCost > 0 && abs((snap.cost ?? -1) - (0.000594 - apiCost)) < 1e-10, "cost=\(snap.cost ?? -1) api=\(apiCost)")
            precondition(snap.unpricedModels == 1 && snap.unpricedBySource["API · Fixture B"] == 1, "未定价计数与总成本同口径")
            try write(".config/vibegauge/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 2, "cache_read": 4, "cache_write": 6, "out": 8]]))
            collector.scanNowForTesting()
            precondition(abs((collector.snapshot().cost ?? -1) - (0.001188 - 2 * apiCost)) < 1e-10)
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
            let restarted = history()
            restarted.scanNowForTesting()
            precondition(restarted.snapshot().totals == snap.totals && restarted.snapshot().error.isEmpty)

            // 折叠：40 天后逐条记录全折成日汇总，统计口径（含会话数、按天、跨文件去重）不变
            func same(_ a: UsageHistory.Snapshot, _ b: UsageHistory.Snapshot) -> Bool {
                if a.totals != b.totals { print("totals 差异", a.totals.filter { b.totals[$0.key] != $0.value }, b.totals.filter { a.totals[$0.key] != $0.value }) }
                if a.days != b.days { print("days 差异", a.days.filter { !b.days.contains($0) }, b.days.filter { !a.days.contains($0) }) }
                return a.totals == b.totals && a.days == b.days && a.cumulativeTurns == b.cumulativeTurns
            }
            let later = UsageHistory(home: root.path); later.clock = { fixedNow + 40 * 86400 }
            later.scanNowForTesting()
            precondition(same(later.snapshot(), snap), "折叠后统计变了")
            let folded = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
            let foldedFiles = folded["files"] as! [String: [String: Any]]
            precondition(folded["version"] as? Int == 4 && foldedFiles.values.filter { $0["source"] as? String != "Claude" }.allSatisfy { ($0["records"] as! [String: Any]).isEmpty },
                          "40 天后 Codex / API 不该再有逐条记录（Claude 保留逐条，跨文件去重要用）")
            // 折叠后重启、再重写一个日志：只撤销它自己的贡献
            let reborn = UsageHistory(home: root.path); reborn.clock = { fixedNow + 40 * 86400 }
            reborn.scanNowForTesting()
            precondition(same(reborn.snapshot(), snap))
            try write(cb, try claude("fixture-6", after, 20, 2))
            reborn.scanNowForTesting()
            precondition(reborn.snapshot().totals["Claude"]?.ctx == 23 && reborn.snapshot().totals["Claude"]?.turns == 2, "折叠后重写：\(String(describing: reborn.snapshot().totals["Claude"]))")
            // 日志删掉：历史保留（按说明清日志不丢账）
            let codexBefore = reborn.snapshot().totals["Codex"]
            try FileManager.default.removeItem(at: root.appendingPathComponent(codexB))
            reborn.scanNowForTesting()
            precondition(reborn.snapshot().totals["Codex"] == codexBefore, "删日志后历史丢了")
        } catch { preconditionFailure("统计临时日志自测失败：\(error)") }

        // 分块读取：跨 1 MB 块边界的长行要完整交出，末尾半行留给下次，偏移停在最后一个换行之后
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-lines-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let long = String(repeating: "a", count: 1_500_000)
            try Data("x\n\(long)\ny\npartial".utf8).write(to: url)
            let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
            var got: [(Int, UInt64)] = []
            let size = UInt64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber)
            let end = try LineReader.read(fh, from: 0, to: size) { line, offset in got.append((line.count, offset)) }
            precondition(got.map(\.0) == [1, 1_500_000, 1] && got.map(\.1) == [0, 2, 1_500_003] && end == 1_500_005, "分块读取：\(got) end=\(end)")
            let resumed = try LineReader.read(fh, from: end, to: size) { _, _ in preconditionFailure("半行不能交出") }
            precondition(resumed == end)
            // 超过单行上限：整行跳过，前后的行照常交出，偏移不乱
            let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("vg-lines-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: url2) }
            try Data("ab\n\(String(repeating: "x", count: 3_000_000))\ncd\n".utf8).write(to: url2)
            let fh2 = try FileHandle(forReadingFrom: url2); defer { try? fh2.close() }
            var got2: [(String, UInt64)] = []
            let end2 = try LineReader.read(fh2, from: 0, to: 3_000_009, maxLine: 1_500_000) { line, offset in got2.append((String(decoding: line, as: UTF8.self), offset)) }
            precondition(got2.map(\.0) == ["ab", "cd"] && got2.map(\.1) == [0, 3_000_004] && end2 == 3_000_007, "超长行跳过：\(got2) end=\(end2)")
        } catch { preconditionFailure("分块读取自测失败：\(error)") }

        // 续接会话的文件里全是复制来的请求：折叠后不重复计量，但仍算一个会话（与折叠前同口径）
        do {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibegauge-dup-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent(".claude/projects/fixture")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = #"{"type":"assistant","timestamp":"2026-09-18T16:00:01Z","requestId":"dup-1","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":2}}}"# + "\n"
            try Data(line.utf8).write(to: dir.appendingPathComponent("a.jsonl"))
            try Data(line.utf8).write(to: dir.appendingPathComponent("b.jsonl"))
            let t0 = Fmt.parseISODate("2026-09-19T00:00:00Z")!
            func at(_ t: TimeInterval) -> UsageHistory.Snapshot { let h = UsageHistory(home: root.path); h.clock = { t }; h.scanNowForTesting(); return h.snapshot() }
            let recent = at(t0), old = at(t0 + 40 * 86400)
            precondition(recent.totals["Claude"]?.turns == 1 && recent.totals["Claude"]?.sessions == 2)
            precondition(old.totals == recent.totals && old.days == recent.days, "复制品折叠后：\(String(describing: old.totals["Claude"]))")
        } catch { preconditionFailure("复制会话自测失败：\(error)") }

        // B 段评审的复现场景：折叠 / 重写 / 删除重建 / 偶发漏遍历都不能丢账或重复
        do {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibegauge-edge-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            let dir = root.appendingPathComponent(".claude/projects/p")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent(".config/vibegauge"), withIntermediateDirectories: true)
            func cl(_ id: String, _ ts: String, _ input: Int) -> String {
                #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(id)","message":{"model":"m","usage":{"input_tokens":\#(input),"output_tokens":0}}}"# + "\n"
            }
            func put(_ rel: String, _ text: String, append: Bool = false) throws {
                let url = root.appendingPathComponent(rel)
                if append, let h = try? FileHandle(forWritingTo: url) { try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close() }
                else { try Data(text.utf8).write(to: url) }
            }
            let t0 = Fmt.parseISODate("2026-09-19T00:00:00Z")!
            let h = UsageHistory(home: root.path); h.clock = { t0 + 40 * 86400 }
            func claudeCtx() -> Int64 { h.scanNowForTesting(); return h.snapshot().totals["Claude"]?.ctx ?? -1 }
            // 跨文件同一请求取时间戳最新的那份（9），与折叠无关
            try put(".claude/projects/p/a.jsonl", cl("r", "2026-09-10T00:00:00Z", 5))
            try put(".claude/projects/p/b.jsonl", cl("r", "2026-09-11T00:00:00Z", 9))
            precondition(claudeCtx() == 9, "取最新时间戳：\(claudeCtx())")
            // 同一文件把旧请求原样再追加一次：不重复
            try put(".claude/projects/p/a.jsonl", cl("r", "2026-09-10T00:00:00Z", 5), append: true)
            precondition(claudeCtx() == 9, "同文件重复追加")
            // 重写 b：它的副本没了，a 里那份要补回来（5）+ 新请求 7
            try put(".claude/projects/p/b.jsonl", cl("s", "2026-09-11T00:00:00Z", 7))
            precondition(claudeCtx() == 12, "重写后另一文件的副本要计入：\(claudeCtx())")
            // api-calls.jsonl 删除后被同名重建：旧一代的账保留
            func api(_ ctx: Int, _ ts: String) -> String { #"{"ts":"\#(ts)","host":"h.test","provider":"P","ctx":\#(ctx),"out":0}"# + "\n" }
            let apiRel = ".config/vibegauge/api-calls.jsonl"
            try put(apiRel, api(5, "2026-09-10T00:00:00Z"))
            func apiCtx() -> Int64 { h.scanNowForTesting(); return h.snapshot().totals["API · P"]?.ctx ?? -1 }
            precondition(apiCtx() == 5)
            try fm.removeItem(at: root.appendingPathComponent(apiRel))
            precondition(apiCtx() == 5, "删日志后历史保留")
            try put(apiRel, api(7, "2026-09-12T00:00:00Z"))
            precondition(apiCtx() == 12, "同名重建：旧 5 + 新 7，实际 \(apiCtx())")
            // 偶发没遍历到（文件挪走一轮又回来，内容不变）：不能归档后从头再算一遍
            let tmp = root.appendingPathComponent("api.bak")
            try fm.moveItem(at: root.appendingPathComponent(apiRel), to: tmp)
            _ = apiCtx()
            try fm.moveItem(at: tmp, to: root.appendingPathComponent(apiRel))
            precondition(apiCtx() == 12, "同一文件重新出现不重复：\(apiCtx())")
        } catch { preconditionFailure("历史边界自测失败：\(error)") }

        // 历史缓存迁移：v3 升级留备份；更新版本写的只读；读坏的挪开不覆盖
        do {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibegauge-migrate-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appendingPathComponent(".config/vibegauge")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cache = dir.appendingPathComponent("usage-daily.json")
            let now = Fmt.parseISODate("2026-09-19T00:00:00Z")!
            func run() -> UsageHistory.Snapshot { let h = UsageHistory(home: root.path); h.clock = { now }; h.scanNowForTesting(); return h.snapshot() }
            // v3：日志早已删除，只剩缓存里的一条 Codex 记录
            let v3 = #"{"version":3,"updatedAt":1,"days":[],"files":{"/gone/a.jsonl":{"source":"Codex","model":"m","size":1,"mtime":1,"offset":1,"head":"","skipped":0,"records":{"0":{"id":"0","source":"Codex","timestamp":1790000000,"model":"m","cumulative":false,"usage":{"ctx":7,"cacheRead":0,"cacheWrite":0,"out":3,"think":0}}}}}}"#
            try Data(v3.utf8).write(to: cache)
            precondition(run().totals["Codex"]?.ctx == 7, "v3 历史没读进来")
            precondition(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage-daily.v3.json").path), "v3 升级前要留备份")
            let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
            precondition(upgraded["version"] as? Int == 4)
            precondition(run().totals["Codex"]?.ctx == 7, "v4 重启后历史还在")
            // 更新版本写的：格式解不开也绝不当成损坏挪走或覆盖
            let future = #"{"version":99,"files":[]}"#
            try Data(future.utf8).write(to: cache)
            _ = run()
            let after99 = String(decoding: try Data(contentsOf: cache), as: UTF8.self)
            precondition(after99 == future, "新版本缓存被覆盖了")
            // 读坏的：挪到旁边保留
            try Data("{not json".utf8).write(to: cache)
            _ = run()
            let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("usage-daily.corrupt-") }
            precondition(kept.count == 1, "坏缓存要另存：\(kept)")
        } catch { preconditionFailure("历史缓存迁移自测失败：\(error)") }

        SelfTestFixtures.run()
    }
}
