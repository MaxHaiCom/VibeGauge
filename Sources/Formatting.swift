import Foundation

// MARK: - 纯展示格式化（可自测）

public enum Fmt {
    /// 外部数据里的百分比 → 0–100 整数：先在 Double 里截断再转 Int（1e308 直接 Int() 会崩），NaN/∞ 当缺失
    public static func pct(_ d: Double?) -> Int? {
        guard let d = d, d.isFinite else { return nil }
        return Int(max(0, min(100, d)).rounded())
    }

    /// "claude-fable-5-1" → "Fable 5.1"；"claude-sonnet-4-5-20250929" → "Sonnet 4.5"；"claude-3-7-sonnet-20250219" → "Sonnet 3.7"
    public static func modelDisplayName(_ raw: String) -> String {
        if raw.isEmpty { return "AI" }
        var s = raw.lowercased()
        for prefix in ["anthropic/", "models/"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        // 只美化 Claude 的命名（claude-opus-5 → Opus 5）；别家的型号名（gpt-6-astra、glm-5.3、deepseek-v4-flash-…）原样显示，
        // 按同一套规则拆会把 gpt-6-astra 变成「Gpt Astra 6」
        guard s.hasPrefix("claude-") else { return String(raw.dropFirst(raw.count - s.count)) }
        s.removeFirst("claude-".count)
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() } // 日期后缀
        let words = parts.filter { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let nums = parts.filter { Int($0) != nil }
        let out = [words.joined(separator: " "), nums.joined(separator: ".")].filter { !$0.isEmpty }.joined(separator: " ")
        return out.isEmpty ? raw : out
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 → epoch。ISO8601DateFormatter 只认 3 位小数秒，grok 写 6 位 → 先截到 3 位
    public static func parseISODate(_ raw: String?) -> TimeInterval? {
        guard var s = raw else { return nil }
        if let r = s.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            s.replaceSubrange(r, with: s[r].prefix(4))
        }
        return (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
    }

    /// 距重置点倒计时："35m" / "1h49m" / "2d10h"；已过 → "已重置"；无数据 → nil
    public static func countdown(to resetsAt: TimeInterval?, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard let r = resetsAt, r.isFinite else { return nil }
        let secs = Int(max(-1, min(r - now, 10 * 365 * 86400)))   // 外部给的时间戳可能离谱，先截断再转 Int
        if secs <= 0 { return L("已重置", "Reset") }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h\(m % 60)m" }
        return "\(h / 24)d\(h % 24)h"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    public static func dateText(_ t: TimeInterval) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: t))
    }

    /// 紧凑相对时间（卡片脚注用）："刚刚" / "12m前" / "16h前" / "3d前"
    public static func agoShort(_ secs: Int) -> String {
        if secs < 60 { return L("刚刚", "just now") }
        if secs < 3600 { return L("\(secs / 60)m前", "\(secs / 60)m ago") }
        if secs < 86400 { return L("\(secs / 3600)h前", "\(secs / 3600)h ago") }
        return L("\(secs / 86400)d前", "\(secs / 86400)d ago")
    }

    private static let usageResetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f
    }()

    /// Codex 额度耗尽文案里的重置时间："...try again at Sep 19th, 2026 5:03 PM." → epoch（按本机时区）
    public static func parseUsageLimitReset(_ message: String) -> TimeInterval? {
        guard let re = try? NSRegularExpression(pattern: #"try again (?:at|on)\s+([A-Za-z]{3,})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})[,\s]+(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]"#) else { return nil }
        let ns = message as NSString
        guard let m = re.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        let month = String(g(1).prefix(3))
        let text = "\(month) \(g(2)), \(g(3)) \(g(4)):\(g(5)) \(g(6).uppercased())M"
        usageResetFormatter.timeZone = TimeZone.current
        return usageResetFormatter.date(from: text)?.timeIntervalSince1970
    }

    /// 最近秩百分位（样本少的时候比插值直观：p95 一定是某次真实调用的耗时）
    public static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let idx = Int((p * Double(s.count)).rounded(.up)) - 1
        return s[max(0, min(s.count - 1, idx))]
    }

    /// 毫秒 → "312ms" / "4.3s" / "1m02s"
    public static func ms(_ v: Int) -> String {
        if v <= 0 { return "—" }
        if v < 1000 { return "\(v)ms" }
        if v < 60_000 { return String(format: "%.1fs", Double(v) / 1000.0) }
        return String(format: "%dm%02ds", v / 60_000, (v % 60_000) / 1000)
    }

    /// 相对时间："刚刚" / "35秒前" / "12分钟前" / "3小时前"
    public static func ago(_ secs: Int) -> String {
        if secs < 8 { return L("刚刚", "just now") }
        if secs < 60 { return L("\(secs)秒前", "\(secs)s ago") }
        if secs < 3600 { return L("\(secs / 60)分钟前", "\(secs / 60)m ago") }
        return L("\(secs / 3600)小时前", "\(secs / 3600)h ago")
    }
}
