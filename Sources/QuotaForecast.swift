import Foundation

/// 一个额度窗口（5h / 周）：已用百分比 + 重置点 + 数据采集时间
/// 按当前速度推算的燃烧情况
public struct Burn: Equatable {
    public let pctPerHour: Double
    /// 照这个速度，到重置点会用到百分之多少（可能 >100）
    public let projectedAtReset: Int
    /// 预计打满的时刻；nil = 到重置也用不完
    public let exhaustAt: TimeInterval?
    /// 这个速度是怎么来的（界面要说清口径）："近 42 分钟" / "本窗口均" / "近 7 天作息"
    public let basis: String
    public var isRecent = false
    /// 按作息推算时：每个「活跃天」用掉多少 %（= 扣掉睡觉时间的日均）；其他口径为 nil
    public var perActiveDay: Double? = nil
}

/// 作息画像：一天 24 个钟点各占多少使用量（和为 1），来自近 7 天本地日志里每次调用的时间。
/// 用来把「距重置还有 3 天」换算成「还有几个活跃天」—— 睡觉、不碰电脑的钟点几乎不算。
public struct ActivityProfile: Equatable {
    public let share: [Double]

    /// 近 7 天调用不足 30 次或只有 1–2 个钟点有记录 → nil，调用方退回旧算法
    public init?(hourCounts: [Double]) {
        guard hourCounts.count == 24 else { return nil }
        let total = hourCounts.reduce(0, +)
        guard total >= 30, hourCounts.filter({ $0 > 0 }).count >= 3 else { return nil }
        // 混 10% 均匀：7 天样本少，某个钟点这周没用过不代表下周绝不会用
        share = hourCounts.map { 0.9 * $0 / total + 0.1 / 24 }
    }

    /// 近 `days` 天里每个钟点（该时区 0…23 点）的调用次数
    public static func hourCounts(_ timestamps: [TimeInterval], now: TimeInterval, days: Double = 7,
                                  timeZone: TimeZone = .current) -> [Double] {
        var counts = [Double](repeating: 0, count: 24)
        for t in timestamps where t <= now && now - t < days * 86400 { counts[hour(t, timeZone)] += 1 }
        return counts
    }

    private static func hour(_ t: TimeInterval, _ tz: TimeZone) -> Int {
        let local = t + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
        return (Int((local / 3600).rounded(.down)) % 24 + 24) % 24
    }

    /// t 之后第一个「钟点可能变」的时刻：下一个当地整点，或更早的时区切换点
    /// （查塔姆群岛这类 02:45 跳 03:45 的夏令时不在整点，只按整点走会把切换后的时间算进旧钟点）。
    /// 每步至少前进一点，循环必停。
    private static func nextBoundary(_ t: TimeInterval, limit: TimeInterval, _ tz: TimeZone) -> TimeInterval {
        let date = Date(timeIntervalSince1970: t)
        let local = t + Double(tz.secondsFromGMT(for: date))
        var next = t + 3600 - local.truncatingRemainder(dividingBy: 3600)
        if let dst = tz.nextDaylightSavingTimeTransition(after: date)?.timeIntervalSince1970, dst > t { next = min(next, dst) }
        return min(limit, next)
    }

    /// [from, to) 里有多少「活跃天」：整整一天 = 1，按钟点占比累加（逐小时走，最多 7×24 步）
    public func activeDays(from: TimeInterval, to: TimeInterval, timeZone: TimeZone = .current) -> Double {
        var t = from, sum = 0.0
        while t < to {
            let next = Self.nextBoundary(t, limit: to, timeZone)
            sum += share[Self.hour(t, timeZone)] * (next - t) / 3600
            t = next
        }
        return sum
    }

    /// 从 from 起按 perDay 的速度消耗，第几秒把 need 个百分点用完；到 limit 还没用完 → nil
    func exhaustTime(from: TimeInterval, limit: TimeInterval, need: Double, perDay: Double,
                     timeZone: TimeZone = .current) -> TimeInterval? {
        var t = from, left = need
        while t < limit {
            let next = Self.nextBoundary(t, limit: limit, timeZone)
            let rate = perDay * share[Self.hour(t, timeZone)] / 3600     // %/秒
            if rate * (next - t) >= left { return t + left / rate }
            left -= rate * (next - t)
            t = next
        }
        return nil
    }

    /// 常用时段：占比比平均高 20% 的钟点连成的区间，如「10–02 点」，首尾跨午夜的会连起来；全天差不多 →「全天」
    public var activeHoursText: String {
        let on = share.map { $0 > 1.2 / 24 }          // 和为 1 → 不可能 24 个都高出 20%，下面的 while 必停
        let ranges = (0..<24).filter { on[$0] && !on[($0 + 23) % 24] }.map { s -> String in
            var e = s
            while on[(e + 1) % 24] { e = (e + 1) % 24 }
            return String(format: "%02d–%02d", s, (e + 1) % 24)
        }
        return ranges.isEmpty ? L("全天", "all day") : ranges.joined(separator: ", ") + L(" 点", "")
    }
}

public struct QuotaWindow: Equatable {
    public var usedPct: Int
    public var resetsAt: TimeInterval?
    public var capturedAt: TimeInterval?
    /// 这个窗口有多长（5h = 18000，周 = 604800）。0 = 不知道 → 不推算，不瞎猜
    public var windowSeconds: Double = 0
    /// 近期速度（本工具自己记的额度采样算出来的，%/小时）。0 = 还没攒够样本
    public var recentPctPerHour: Double = 0
    public var recentSpanMinutes: Int = 0
    /// 上一个周期结束时用到了百分之多少（采样器在跨过重置点时记下）。nil = 没赶上
    public var lastCyclePct: Int? = nil
    /// 滚动窗口（按请求数估的 Coding Plan）：每笔请求满窗口时长后各自释放，没有整体重置点。
    /// 此时 resetsAt = 下一笔释放的时刻，releaseCount = 那一分钟内释放几次；
    /// 「过点归零」「到重置前会用到多少」都只对固定窗口成立。
    public var isRolling = false
    public var releaseCount = 0
    /// 本机按记账估出来的（套餐请求数 / 系数估算），不是厂商回报：不做预测提醒，界面标「估算」
    public var isEstimate = false

    public func isExpired(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard !isRolling, let r = resetsAt else { return false }
        return now >= r
    }

    /// 这个数能信到什么程度。过了重置点 = 新周期还没回报（不是 0%）；旧数据不拿去预测、不据此提醒。
    public enum Trust: Equatable { case reported, estimated, stale, awaiting }
    public func trust(now: TimeInterval = Date().timeIntervalSince1970) -> Trust {
        if isExpired(now: now) { return .awaiting }
        if isRolling || isEstimate { return .estimated }
        // 数据源只在 CLI 被用时刷新：超过窗口 1/5（5h → 1h，周 → 约 1.4 天）没更新，期间别处的用量可能没算进来
        // 窗口长度不知道（Grok 缺周期起点、API 限流头）：24 小时没更新也算可能过期
        if let age = ageSeconds(now: now), Double(age) > (windowSeconds > 0 ? windowSeconds / 5 : 86400) { return .stale }
        return .reported
    }
    public func trustText(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        switch trust(now: now) {
        case .reported: return L("官方回报", "Reported")
        case .estimated: return L("本机估算", "Estimated")
        case .stale: return L("可能过期", "May be stale")
        case .awaiting: return L("等待新回报", "Awaiting update")
        }
    }

    /// 「重置 1h2m」/ 滚动窗口「1h2m 后释放 3 次」；没有时刻就 nil
    public func resetText(now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        if isRolling, let r = resetsAt, r <= now { return L("待刷新", "refreshing") }   // 下一轮扫描会重算，不是「已重置」
        guard let c = Fmt.countdown(to: resetsAt, now: now) else { return nil }
        return isRolling ? L("\(c) 后释放 \(max(1, releaseCount)) 次", "frees \(max(1, releaseCount)) in \(c)") : L("重置 \(c)", "resets \(c)")
    }
    /// 窄位置用：固定窗口只写倒计时，滚动窗口加「释放」免得被读成重置
    public func shortResetText(now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        if isRolling, let r = resetsAt, r <= now { return L("待刷新", "refreshing") }
        guard let c = Fmt.countdown(to: resetsAt, now: now) else { return nil }
        return isRolling ? L("\(c) 释放", "frees \(c)") : c
    }

    /// 过了重置点 → 缓存里的旧值作废，视为 0%
    public func effectivePct(now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        isExpired(now: now) ? 0 : usedPct
    }

    public func ageSeconds(now: TimeInterval = Date().timeIntervalSince1970) -> Int? {
        capturedAt.map { max(0, Int(now - $0)) }
    }

    /// 燃烧速率。按窗口长短分两种思路：
    /// - **周这类 ≥1 天的窗口 + 有作息画像**：按「活跃天」算 —— 本周期已用 ÷ 已过的活跃天 = 每活跃天用多少，
    ///   再乘剩下的活跃天。睡觉的钟点几乎不计，所以夜里不会把白天的速度外推一整晚。
    ///   上周期终值当先验（算 1 个活跃天的分量）：刚重置时本周期样本少，先信上周期，越往后越信本周期。
    /// - **其他**（5h 窗口 / 没画像）：旧口径，优先"近期"（近 1 小时两点差），否则"窗口均"。
    /// 窗口刚开头样本不够、没窗口长度、已过重置、已经打满 → 一律不推算。
    public func burn(now: TimeInterval = Date().timeIntervalSince1970, profile: ActivityProfile? = nil,
                     timeZone: TimeZone = .current) -> Burn? {
        guard windowSeconds > 0, !isRolling, let reset = resetsAt else { return nil }   // 滚动窗口没有终点可推
        // 旧数据 / 已过重置点：拿它推未来会误导（界面和提醒都不给预测）
        let t = trust(now: now)
        guard t != .stale && t != .awaiting else { return nil }
        let remaining = reset - now
        guard remaining > 0 else { return nil }                       // 已过重置点，旧值作废
        let elapsed = windowSeconds - remaining
        let pct = Double(effectivePct(now: now))
        guard pct < 100 else { return nil }                           // 已经打满了就没什么可推算的

        if windowSeconds >= 86400, let profile {
            let doneDays = profile.activeDays(from: reset - windowSeconds, to: now, timeZone: timeZone)
            let leftDays = profile.activeDays(from: now, to: reset, timeZone: timeZone)
            let perDay: Double
            if let last = lastCyclePct {
                perDay = (pct + Double(last) / (windowSeconds / 86400)) / (doneDays + 1)
            } else {
                guard doneDays >= 0.25, pct > 0 else { return nil }  // 不到 1/4 个活跃天，一小时的猛用会被外推成几倍
                perDay = pct / doneDays
            }
            let projected = pct + perDay * leftDays
            let exhaust = projected >= 100 && perDay > 0
                ? profile.exhaustTime(from: now, limit: reset, need: 100 - pct, perDay: perDay, timeZone: timeZone) : nil
            let basis = lastCyclePct.map { L("作息 · 上周期 \($0)%", "pattern · last \($0)%") } ?? L("按作息", "pattern")
            return Burn(pctPerHour: perDay / 24, projectedAtReset: Int(projected.rounded()), exhaustAt: exhaust,
                        basis: basis, perActiveDay: perDay)
        }

        var perHour: Double
        var basis: String
        let recent = recentSpanMinutes >= 10                   // 有 10 分钟以上的样本就用近期速度，哪怕是 0
        if recent {
            perHour = recentPctPerHour
            basis = L("近 \(recentSpanMinutes) 分钟", "last \(recentSpanMinutes)m")
        } else {
            guard elapsed >= 900, pct > 0 else { return nil }
            perHour = pct / (elapsed / 3600)
            basis = L("本窗口均", "window average")
        }
        let projected = pct + perHour * (remaining / 3600)
        let exhaust: TimeInterval? = projected >= 100 && perHour > 0 ? now + (100 - pct) / perHour * 3600 : nil
        return Burn(pctPerHour: perHour, projectedAtReset: Int(projected.rounded()), exhaustAt: exhaust, basis: basis, isRecent: recent)
    }
}


/// 「预计会在重置前打满」的候选：只看官方回报的固定窗口（估算 / 过期 / 等新回报的都不报）
public struct ForecastCandidate: Equatable {
    public let key: String            // 平台 + 池 + 重置点：一个周期一个键
    public let title: String
    public let body: String
    public let exhaustAt: TimeInterval

    /// id = 稳定身份（卡片 ID + 固定池名，不随界面语言、显示名变）；platform / pool 只用于文案
    public static func find(in windows: [(id: String, platform: String, pool: String, window: QuotaWindow?, profile: ActivityProfile?)],
                            now: TimeInterval) -> [ForecastCandidate] {
        windows.compactMap { item in
            guard let w = item.window, w.trust(now: now) == .reported, w.effectivePct(now: now) < 100,
                  let reset = w.resetsAt, reset.isFinite, abs(reset) < 1e15, let b = w.burn(now: now, profile: item.profile),
                  let at = b.exhaustAt, at < reset,
                  let eta = Fmt.countdown(to: at, now: now), let left = Fmt.countdown(to: reset, now: now) else { return nil }
            return ForecastCandidate(
                key: "forecast:\(item.id)@\(Int(reset))",
                title: L("📈 预计打满 · \(item.platform) \(item.pool)", "📈 Projected to run out · \(item.platform) \(item.pool)"),
                body: L("已用 \(w.effectivePct(now: now))%，照目前节奏（\(b.basis)）约 \(eta) 后打满，离重置还有 \(left)。这是预计，不是已经用完。",
                        "\(w.effectivePct(now: now))% used; at the current pace (\(b.basis)) it runs out in about \(eta), with \(left) left until the reset. This is a projection."),
                exhaustAt: at)
        }
    }
}

// 额度采样：记 (时刻, 已用%) 算近期速度，归档上周期终值给预测当先验
extension ProcessScanner {
    // MARK: 额度采样（算"当前节奏"用）

    var samplesPath: String { "\(home)/.config/vibegauge/quota-samples.json" }
    static let sampleKeep: TimeInterval = 6 * 3600
    static let sampleEvery: TimeInterval = 55          // 扫描每 8s 一次，别记那么密

    func loadSamples() {
        guard !qsamplesLoaded else { return }
        qsamplesLoaded = true
        guard let json = readJSON(samplesPath) else { return }
        for (k, v) in json {
            guard let arr = v as? [[Double]] else { continue }
            qsamples[k] = arr.compactMap { $0.count == 2 ? (t: $0[0], pct: Int($0[1])) : nil }
        }
    }

    func saveSamplesIfDue(_ now: TimeInterval) {
        guard now - qsamplesSavedAt >= 120 else { return }
        qsamplesSavedAt = now
        var out: [String: [[Double]]] = [:]
        for (k, arr) in qsamples { out[k] = arr.map { [$0.t, Double($0.pct)] } }
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { return }
        do {
            let dir = "\(home)/.config/vibegauge"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            try data.write(to: URL(fileURLWithPath: samplesPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: samplesPath)
        } catch {
            log.error("额度样本保存失败")
        }
    }

    /// 同一额度里重置点已过的最近一个旧窗口 → 它在重置前的最后一笔 = 上周期终值。
    /// 只取重置前的样本：数据源刷新滞后时，重置后还会用旧重置点记一笔 0%，那不是终值。
    static func finishedCycle(_ samples: [String: [(t: TimeInterval, pct: Int)]], rawKey: String,
                              now: TimeInterval) -> (reset: TimeInterval, pct: Int)? {
        samples.compactMap { k, arr -> (reset: TimeInterval, pct: Int)? in
            guard k.hasPrefix(rawKey + "@"), let r = Double(k.dropFirst(rawKey.count + 1)), r <= now,
                  let last = arr.last(where: { $0.t < r }) else { return nil }
            // 最后一次观测离重置太远 → 那只是「当时用到多少」，不是终值（当先验会系统性偏低）
            let maxGap: TimeInterval = rawKey.hasSuffix("5h") ? 1800 : 12 * 3600
            guard r - last.t <= maxGap else { return nil }
            return (r, last.pct)
        }.max { $0.reset < $1.reset }
    }

    /// 旧窗口的样本 6 小时后就清掉，清之前把终值挪到 final2| 键下长期留着（每个额度只留最近一个）。
    /// 必须对**所有**额度一起归档：同一轮里先采的 5h 会顺手清掉过期的周样本，只归档自己的话周额度就丢了终值
    /// （合盖睡一晚跨过周重置就会碰上）。
    static func archiveFinals(_ samples: inout [String: [(t: TimeInterval, pct: Int)]], now: TimeInterval) {
        let raws = Set(samples.keys.compactMap { k -> String? in
            guard !k.hasPrefix("final2|"), let at = k.range(of: "@", options: .backwards) else { return nil }
            return String(k[..<at.lowerBound])
        })
        for raw in raws {
            if let fin = finishedCycle(samples, rawKey: raw, now: now), (samples["final2|\(raw)"]?.last?.t ?? 0) < fin.reset {
                samples["final2|\(raw)"] = [(t: fin.reset, pct: fin.pct)]
            }
        }
    }

    /// 记一笔样本，并把"近期速度"与"上周期终值"回填进窗口。lookback 内取最老的一个样本做两点差。
    func sampleAndFill(_ w: inout QuotaWindow, key rawKey: String, now: TimeInterval) {
        guard !w.isRolling else { return }        // 「重置点」随每笔请求变，按它分键只会堆垃圾样本
        guard let reset = w.resetsAt, reset.isFinite, abs(reset) < 1e15 else { return }   // 离谱的时间戳转 Int 会崩
        loadSamples()
        let key = "\(rawKey)@\(Int(reset))"
        Self.archiveFinals(&qsamples, now: now)
        let finalKey = "final2|\(rawKey)"
        // 只认紧挨着的几个周期：App 停了一个月再开，一个月前的终值没有参考价值
        if let f = qsamples[finalKey]?.last, f.t < reset, f.t > reset - 3 * w.windowSeconds { w.lastCyclePct = f.pct }
        var arr = qsamples[key] ?? []
        // 样本时间 = 厂商数据自己的采集时间：同一份旧观测不能按扫描时间一遍遍记成「新样本」
        let observed = min(now, w.capturedAt ?? now)
        if arr.last.map({ observed - $0.t >= Self.sampleEvery }) ?? true {
            arr.append((t: observed, pct: w.effectivePct(now: observed)))
            arr.removeAll { now - $0.t > Self.sampleKeep }
            qsamples[key] = arr
            // 键会随窗口重置而变，老键留着没用 —— 顺手清掉超过保留期的整条（final2| 终值除外）
            qsamples = qsamples.filter { $0.key.hasPrefix("final2|") || !($0.value.last.map { now - $0.t > Self.sampleKeep } ?? true) }
        }
        // 最新样本前 1 小时内最老的那个 → 两点差。跨度不足 10 分钟不算（噪声太大）；最新观测都超过 1 小时了也不算（不是「近期」）
        guard let latest = arr.last, now - latest.t <= 3600,
              let oldest = arr.first(where: { latest.t - $0.t <= 3600 }) else { return }
        let spanSec = latest.t - oldest.t
        guard spanSec >= 600 else { return }
        let delta = Double(latest.pct - oldest.pct)
        guard delta >= 0 else { return }                      // 只会涨；掉了说明数据源换了口径，别用
        w.recentPctPerHour = delta / (spanSec / 3600)         // 0 也是有效结论：最近一小时确实没用
        w.recentSpanMinutes = Int(spanSec / 60)
    }

    /// 给一个平台的所有额度窗口记样本（在 scanActiveLLMs 末尾统一做，卡片与详情页都能拿到）
    func sampleLLMQuotas(_ llm: inout DetectedLLMRuntime, now: TimeInterval) {
        if llm.fiveHour != nil { sampleAndFill(&llm.fiveHour!, key: "\(llm.name)|5h", now: now) }
        if llm.sevenDay != nil { sampleAndFill(&llm.sevenDay!, key: "\(llm.name)|w", now: now) }
        // 副池键带池名：显示的副池换了（A → B）不能继承 A 的样本和上周期终值
        let sec = llm.secondaryPoolName
        if llm.secondaryFiveHour != nil { sampleAndFill(&llm.secondaryFiveHour!, key: "\(llm.name)|sec:\(sec)|5h", now: now) }
        if llm.secondarySevenDay != nil { sampleAndFill(&llm.secondarySevenDay!, key: "\(llm.name)|sec:\(sec)|w", now: now) }
    }
}
