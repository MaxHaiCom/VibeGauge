import SwiftUI
import Foundation

/// 展示层只读快照；历史归并、定价和日历归桶均由后台完成。
public struct StatsTabView: View {
    public let snapshot: UsageHistory.Snapshot
    public init(snapshot: UsageHistory.Snapshot) { self.snapshot = snapshot }
    @AppStorage("vg.heatmapHourly") private var heatmapHourly = false
    @State private var monthOffset = 0

    private var hasRecords: Bool { snapshot.aggregate.turns > 0 }
    private var sources: [String] { ["Claude", "Codex"] + snapshot.totals.keys.filter { $0 != "Claude" && $0 != "Codex" }.sorted() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isScanning || snapshot.capturedAt == 0 {
                Text(L("正在汇总历史（已处理 \(snapshot.processedFiles)/\(snapshot.totalFiles) 个文件）…", "Summarizing history (\(snapshot.processedFiles)/\(snapshot.totalFiles) files) …"))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            if !snapshot.error.isEmpty {
                Text(snapshot.error).font(.system(size: 9)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            metrics
            heatmap
            distribution
            todayModels
            providers
            Text(L("总数与热力图只算 CLI 日志；经记账代理的 API 调用多半已在 CLI 日志里，单列不重复计入。会话数按不同日志文件计，思考包含在输出中。", "Totals and the heatmap use CLI logs only. Most API calls through the accounting proxy are already in CLI logs, so they are not counted twice. Sessions count distinct log files; reasoning is included in output."))
                .font(.system(size: 8)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if snapshot.cumulativeTurns > 0 {
                Text(L("\(snapshot.cumulativeTurns) 次旧格式 Codex 记录按累计差归桶（首条以 0 为基线），跨日精度受事件时间限制。", "\(snapshot.cumulativeTurns) legacy Codex records bucketed by cumulative deltas (first record is the zero baseline); cross-day precision depends on event timestamps."))
                    .font(.system(size: 8)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.skippedRecords > 0 {
                Text(L("\(snapshot.skippedRecords) 条记录缺少有效时间或用量，未计入。", "\(snapshot.skippedRecords) records lacked valid timestamps or usage and were skipped."))
                    .font(.system(size: 8)).foregroundColor(.orange)
            }
        }
        .frame(width: 331, alignment: .leading)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                metric(L("累计 token", "Total tokens"), hasRecords ? Fmt.tokens(snapshot.tokenTotal) : L("未检测到", "Unavailable"), L("输入（含缓存）+ 输出", "input (including cache) + output"))
                metric(L("API 等价成本", "API-equivalent cost"), costText(snapshot.cost), snapshot.hasPriceTable && snapshot.unpricedModels > 0 ? L("部分模型未定价", "Some models unpriced") : L("仅按本地价目表计算", "Local price table only"))
                metric(L("活跃天数", "Active days"), hasRecords ? "\(snapshot.activeDays)" : L("未检测到", "Unavailable"), L("有 token 用量的日历日", "Calendar days with token usage"))
                metric(L("缓存命中率", "Cache hit rate"), snapshot.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? L("查不到", "Unavailable"), L("缓存读取 / 全部输入", "cache reads / all input"))
            }
            Text(snapshot.earliestDate.map { L("自 \($0) 起统计", "Since \($0)") } ?? L("尚无带有效时间与用量的本地记录", "No local records with valid timestamps and usage"))
                .font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.secondary.opacity(0.06)).cornerRadius(8)
    }

    private func costText(_ value: Double?) -> String {
        guard snapshot.hasPriceTable else { return L("未配置价目表", "Price table not configured") }
        guard let value else { return L("未定价", "Unpriced") }
        return String(format: "%.2f %@", value, snapshot.priceCurrency)
    }

    /// 每日强度：默认按月日历（一行 7 天，周一开头，和日历对得上）；点一下切到「近 7 天 × 24 小时」，再点切回
    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(heatmapHourly ? L("时段强度 · 近 7 天", "By hour · last 7 days") : L("每日强度 · \(monthTitle)", "Daily intensity · \(monthTitle)"))
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                if !heatmapHourly {
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                        .disabled(monthOffset <= -11)
                    Button { monthOffset = min(0, monthOffset + 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                        .disabled(monthOffset == 0)
                }
                Text(heatmapHourly ? L("点按看月历", "Tap for month") : L("点按看时段", "Tap for hours"))
                    .font(.system(size: 8)).foregroundColor(.secondary)
            }
            .font(.system(size: 9)).foregroundColor(.secondary)
            if heatmapHourly { hourlyGrid } else { monthGrid }
            HStack {
                Text(heatmapHourly ? L("更早的记录已按天汇总，没有时段", "Older records are daily totals only") : maxDayText)
                Spacer()
                Text(L("少", "Less"))
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1).fill(heatColor(level)).frame(width: 7, height: 7)
                }
                Text(L("多", "More"))
            }.font(.system(size: 8)).foregroundColor(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06)).cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { heatmapHourly.toggle() }
    }

    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.10) : Color.green.opacity(0.15 + Double(level) * 0.15)
    }

    /// 周一开头的当月日历：monthOffset = 0 是本月，-1 上个月…
    private var monthStart: Date {
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return cal.date(byAdding: .month, value: monthOffset, to: first)!
    }
    private var monthTitle: String {
        let c = Calendar.current.dateComponents([.year, .month], from: monthStart)
        return L("\(c.year!) 年 \(c.month!) 月", String(format: "%04d-%02d", c.year!, c.month!))
    }

    private var monthGrid: some View {
        let cal = Calendar.current
        let start = monthStart
        let count = cal.range(of: .day, in: .month, for: start)!.count
        let lead = (cal.component(.weekday, from: start) + 5) % 7          // 周一 = 0
        let cells: [Date?] = Array(repeating: nil, count: lead) + (0..<count).map { cal.date(byAdding: .day, value: $0, to: start) }
            + Array(repeating: nil, count: (7 - (lead + count) % 7) % 7)
        let keys = cells.map { $0.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) } }
        let values = keys.map { $0.flatMap { snapshot.dailyTokens[$0] } ?? 0 }
        // 颜色深浅按近一年所有活跃日分档：翻到只有两三天数据的月份也不会失真
        let reference = Array(snapshot.dailyTokens.values)
        let grades = Array(UsageHistory.levels(reference + values).suffix(values.count))
        let today = cal.startOfDay(for: Date())
        let heads = [L("一", "Mo"), L("二", "Tu"), L("三", "We"), L("四", "Th"), L("五", "Fr"), L("六", "Sa"), L("日", "Su")]
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(heads[i]).font(.system(size: 8)).foregroundColor(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<(cells.count / 7), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        let i = row * 7 + col
                        if let d = cells[i] {
                            dayCell(d, today: today, grade: grades[i], tip: "\(keys[i] ?? "") · \(Fmt.tokens(values[i])) token")
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 16)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ d: Date, today: Date, grade: Int, tip: String) -> some View {
        let future = d > today
        let border: Color = d == today ? Color.primary.opacity(0.6) : Color.secondary.opacity(future ? 0.15 : 0)
        return RoundedRectangle(cornerRadius: 3)
            .fill(future ? Color.clear : heatColor(grade))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
            .overlay(Text("\(Calendar.current.component(.day, from: d))").font(.system(size: 7.5))
                .foregroundColor(grade >= 4 ? Color.black.opacity(0.7) : Color.secondary))
            .frame(maxWidth: .infinity).frame(height: 16)
            .help(tip)
    }

    /// 近 7 天（行，今天在最下）× 24 小时（列）
    private var hourlyGrid: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dates = (0..<7).map { cal.date(byAdding: .day, value: $0 - 6, to: today)! }
        let keys = dates.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) }
        let values = keys.flatMap { k in (0..<24).map { snapshot.hourlyTokens["\(k)#\($0)"] ?? 0 } }
        let grades = UsageHistory.levels(values)
        return VStack(spacing: 2) {
            HStack(spacing: 1.5) {
                Text("").frame(width: 34)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? "\(h)" : " ").font(.system(size: 7.5)).foregroundColor(.secondary)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 1.5) {
                    Text("\(monthDay(dates[row])) \(weekday(dates[row]))").font(.system(size: 7.5)).foregroundColor(.secondary)
                        .frame(width: 34, alignment: .leading).lineLimit(1)
                    ForEach(0..<24, id: \.self) { h in
                        let i = row * 24 + h
                        RoundedRectangle(cornerRadius: 2).fill(heatColor(grades[i]))
                            .frame(maxWidth: .infinity).frame(height: 13)
                            .help("\(keys[row]) \(h):00–\(h + 1):00 · \(Fmt.tokens(values[i])) token")
                    }
                }
            }
        }
    }

    private var maxDayText: String {
        let cal = Calendar.current
        let n = cal.range(of: .day, in: .month, for: monthStart)!.count
        let visible = Set((0..<n).map { UsageHistory.dayKey(timestamp: cal.date(byAdding: .day, value: $0, to: monthStart)!.timeIntervalSince1970) })
        guard let day = snapshot.dailyTokens.filter({ $0.value > 0 && visible.contains($0.key) }).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else { return L("最多的一天：未检测到", "Top day: unavailable") }
        let parts = day.key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? L("最多的一天：\(parts[1])月\(parts[2])日", "Top day: \(parts[1])-\(parts[2])") : L("最多的一天：\(day.key)", "Top day: \(day.key)")
    }
    private func monthDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
    private func weekday(_ date: Date) -> String {
        [L("日", "Su"), L("一", "Mo"), L("二", "Tu"), L("三", "We"), L("四", "Th"), L("五", "Fr"), L("六", "Sa")][Calendar.current.component(.weekday, from: date) - 1]
    }

    private var distribution: some View {
        let all = snapshot.aggregate
        let parts: [(String, Int64, Color)] = [(L("新输入", "New input"), all.newInput, .blue), (L("输出", "Output"), all.out, .orange), (L("缓存", "Cache"), all.cacheTotal, .green)]
        let total = max(1, all.newInput + all.out + all.cacheTotal)
        return section(L("token 分布", "Token distribution")) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2.opacity(0.8)).frame(width: geo.size.width * CGFloat(Double(part.1) / Double(total)))
                    }
                }.cornerRadius(3)
            }.frame(height: 7)
            ForEach(parts, id: \.0) { part in
                HStack(spacing: 4) {
                    Circle().fill(part.2).frame(width: 5, height: 5)
                    Text(part.0)
                    Spacer()
                    Text(hasRecords ? Fmt.tokens(part.1) : L("未检测到", "Unavailable"))
                    if part.0 == L("输出", "Output"), all.think > 0 { Text(L("含思考 \(Fmt.tokens(all.think))", "includes \(Fmt.tokens(all.think)) reasoning")) }
                }.font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private static let mixColors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]

    private var todayModels: some View {
        let today = UsageHistory.dayKey(timestamp: Date().timeIntervalSince1970)
        let mix = UsageHistory.modelMix(snapshot.days.first { $0.date == today })
        let total = max(1, mix.reduce(Int64(0)) { $0 + $1.usage.tokenTotal })
        let shown = Array(mix.prefix(6))
        let rest = mix.dropFirst(6).reduce(Int64(0)) { $0 + $1.usage.tokenTotal }
        return section(L("今日模型构成", "Today's model mix")) {
            if mix.isEmpty {
                Text(L("今天还没有 CLI 用量", "No CLI usage today")).font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, m in
                            Rectangle().fill(Self.mixColors[i].opacity(0.8)).frame(width: geo.size.width * CGFloat(Double(m.usage.tokenTotal) / Double(total)))
                        }
                    }.cornerRadius(3)
                }.frame(height: 7)
                ForEach(Array(shown.enumerated()), id: \.offset) { i, m in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Self.mixColors[i]).frame(width: 5, height: 5)
                            Text(m.model == "?" ? L("未知模型", "Unknown model") : Fmt.modelDisplayName(m.model)).lineLimit(1)
                            Spacer()
                            Text(Fmt.tokens(m.usage.tokenTotal))
                            Text(String(format: "%.0f%%", Double(m.usage.tokenTotal) / Double(total) * 100)).frame(width: 30, alignment: .trailing)
                        }.font(.system(size: 9))
                        Text(L("缓存读 \(Fmt.tokens(m.usage.cacheRead)) · 输出 \(Fmt.tokens(m.usage.out))", "cache read \(Fmt.tokens(m.usage.cacheRead)) · output \(Fmt.tokens(m.usage.out))"))
                            .font(.system(size: 8)).foregroundColor(.secondary).padding(.leading, 9)
                    }
                }
                if rest > 0 {
                    Text(L("其他 \(mix.count - shown.count) 个模型 \(Fmt.tokens(rest))", "\(mix.count - shown.count) other models \(Fmt.tokens(rest))")).font(.system(size: 8)).foregroundColor(.secondary)
                }
                Text(L("按 token 计（输入含缓存 + 输出）。不是订阅额度占比：各家额度按模型怎么折算不公开。", "By tokens (input including cache + output). Not a share of your subscription quota: how plans weight each model is not published."))
                    .font(.system(size: 8)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources, id: \.self) { source in
                if let totals = snapshot.totals[source] {
                    providerCard(source, totals)
                } else {
                    section(source) {
                        Text(snapshot.sourceNotes[source] ?? (snapshot.isScanning ? L("正在汇总…", "Summarizing …") : L("查不到：未检测到有效用量记录", "Unavailable: no valid usage records")))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            section("Grok / Gemini") {
                Text(L("本地无 token 统计", "No local token stats")).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private func providerCard(_ source: String, _ totals: UsageHistory.Totals) -> some View {
        let ratio = snapshot.tokenTotal > 0 ? Double(totals.tokenTotal) / Double(snapshot.tokenTotal) : 0
        return section(source) {
            HStack {
                Text("\(Fmt.tokens(totals.tokenTotal)) token").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(UsageHistory.isProxySource(source) ? L("不计入总数", "Not included in total") : String(format: "%.1f%%", ratio * 100))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            HStack {
                Text(L("\(totals.sessions) 会话 · \(totals.turns) 请求", "\(totals.sessions) sessions · \(totals.turns) requests"))
                Spacer()
                Text(costText(snapshot.costBySource[source]))
            }.font(.system(size: 9)).foregroundColor(.secondary)
            if snapshot.hasPriceTable, snapshot.unpricedBySource[source, default: 0] > 0 {
                Text(L("部分模型未定价", "Some models unpriced")).font(.system(size: 8)).foregroundColor(.orange)
            }
            if let note = snapshot.sourceNotes[source] { Text(note).font(.system(size: 8)).foregroundColor(.secondary) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.65)).frame(width: geo.size.width * ratio)
                }
            }.frame(height: 4)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            content()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06)).cornerRadius(8)
    }
}
