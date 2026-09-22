import SwiftUI
import Foundation

/// 网络页只接收缓存快照；所有采集都由 NetworkScanner 的后台队列完成，避免菜单栏主线程被命令或网络请求卡住。
public struct NetworkTabView: View {
    public let snapshot: NetworkSnapshot
    public let onRetest: () -> Void
    public let width: CGFloat

    public init(snapshot: NetworkSnapshot, onRetest: @escaping () -> Void = {}, width: CGFloat = 331) {
        self.snapshot = snapshot; self.onRetest = onRetest; self.width = width
    }

    private var traceExits: [AIExitStatus] { snapshot.aiExits.filter { !$0.isGemini } }

    private var exitSummary: String {
        let good = traceExits.filter { !$0.ip.isEmpty && $0.error.isEmpty }
        guard !good.isEmpty else { return L("出口暂不可用：查不到 AI trace", "Egress unavailable: no AI trace") }
        let groups = Dictionary(grouping: good, by: { "\($0.ip)|\($0.loc)" })
        if groups.count == 1 { return L("\(good.count) 家 AI 同一出口 · \(good[0].loc.isEmpty ? "国家未知" : good[0].loc)", "\(good.count) AI tools share one egress · \(good[0].loc.isEmpty ? "country unknown" : good[0].loc)") }
        let places = good.map { "\($0.name.replacingOccurrences(of: "/Codex", with: "")) \($0.loc.isEmpty ? L("未知", "unknown") : $0.loc)" }.joined(separator: " / ")
        return L("出口不一致：\(places) ⚠️", "Mismatched egress: \(places) ⚠️")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(L("网络", "Network"))
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if snapshot.isRefreshing { ProgressView().controlSize(.mini) }
                Button(action: onRetest) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L("立即重测（10 秒内最多一次）", "Retest now (at most once every 10s)"))
            }
            .padding(.horizontal, 10)
            Text(exitSummary)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(exitSummary.contains(L("不一致", "Mismatched")) ? .orange : .secondary)
                .lineLimit(2)
                .padding(.horizontal, 10)

            section(L("AI 出口", "AI egress")) { aiExitSection }
            section(L("代理内核", "Proxy core")) { proxySection }
            section(L("本机", "Local network")) { localSection }
            section(L("泄漏体检", "Leak checks")) { leakSection }
        }
        .frame(width: width, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var aiExitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.aiExits) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1).frame(width: 92, alignment: .leading)
                        if item.isGemini {
                            Text(L("由活动连接判断", "Based on active connections"))
                                .font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary)
                        } else if !item.error.isEmpty {
                            Text(L("查不到", "Unavailable")).font(.system(size: 9.5)).foregroundColor(.orange)
                                .help(item.error)
                        } else {
                            Text(item.ip.isEmpty ? L("查不到", "Unavailable") : item.ip)
                                .font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .help(item.ip.isEmpty ? L("未检测到出口 IP", "No egress IP detected") : item.ip)
                        }
                        Spacer(minLength: 0)
                        if item.changed {
                            Text(L("变过", "Changed")).font(.system(size: 8, weight: .bold)).padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18)).foregroundColor(.orange).cornerRadius(3)
                                .help(L("旧 IP：\(item.previousIP) → 新 IP：\(item.changedNewIP.isEmpty ? item.ip : item.changedNewIP) · \(item.previousAt > 0 ? Fmt.dateText(item.previousAt) : "时间未知")", "Old IP: \(item.previousIP) → new IP: \(item.changedNewIP.isEmpty ? item.ip : item.changedNewIP) · \(item.previousAt > 0 ? Fmt.dateText(item.previousAt) : "time unknown")"))
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(!item.error.isEmpty ? item.error : item.isGemini ? L("等待连接表采集", "Waiting for connection table") : L("国家 \(item.loc.isEmpty ? "—" : item.loc) · 机房 \(item.colo.isEmpty ? "—" : item.colo)", "country \(item.loc.isEmpty ? "—" : item.loc) · colo \(item.colo.isEmpty ? "—" : item.colo)"))
                            .font(.system(size: 8.8)).foregroundColor(item.error.isEmpty || item.isGemini ? .secondary : .orange).lineLimit(2)
                            .help(item.error)
                        Spacer(minLength: 0)
                        if !item.isGemini {
                            Text(item.latencyMS > 0 ? "\(item.latencyMS)ms" : "—").font(.system(size: 8.5)).foregroundColor(.secondary)
                            if item.capturedAt > 0 { Text(Fmt.ago(max(0, Int(Date().timeIntervalSince1970 - item.capturedAt)))).font(.system(size: 8.5)).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            if traceExits.allSatisfy({ $0.capturedAt == 0 }) { Text(L("等待后台采集…", "Waiting for background collection …")).font(.system(size: 9)).foregroundColor(.secondary) }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !snapshot.proxy.error.isEmpty {
                Text(snapshot.proxy.error).font(.system(size: 9.5)).foregroundColor(.secondary)
            } else {
                HStack {
                    Text(snapshot.proxy.running ? L("运行中", "Running") : L("未检测到", "Unavailable"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(snapshot.proxy.running ? .green : .secondary)
                    if !snapshot.proxy.version.isEmpty { Text("· \(snapshot.proxy.version)").font(.system(size: 9)).foregroundColor(.secondary) }
                }
                ForEach(snapshot.proxy.groups) { group in
                    HStack(spacing: 5) {
                        Text(group.name).font(.system(size: 9.5)).lineLimit(1)
                        Text(group.type).font(.system(size: 8)).foregroundColor(.secondary)
                        Spacer(); Text(group.now.isEmpty ? L("未选择", "Not selected") : group.now).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                    }
                }
                ForEach(snapshot.proxy.connections) { c in
                    if c.count > 0 {
                        HStack(spacing: 5) {
                            Text(c.name).font(.system(size: 9.5)); Text(L("\(c.count) 连接", "\(c.count) connections")).font(.system(size: 9)).foregroundColor(.secondary)
                            if !c.chains.isEmpty { Text(c.chains.joined(separator: L("、", ", "))).font(.system(size: 8.5)).foregroundColor(.secondary).lineLimit(1) }
                        }
                        if !c.rules.isEmpty {
                            Text(L("规则：", "Rules: ") + c.rules.joined(separator: " / ")).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            localRow(L("默认路由", "Gateway"), value: snapshot.local.gateway.isEmpty ? L("查不到（系统未提供默认路由）", "Unavailable (system provided no default route)") : "\(snapshot.local.gateway) · \(snapshot.local.interfaceName)")
            localRow("IPv4", value: snapshot.local.ipv4.isEmpty ? L("未检测到接口 IPv4", "No interface IPv4 detected") : snapshot.local.ipv4)
            localRow("IPv6", value: snapshot.local.ipv6.isEmpty ? L("未检测到 global IPv6", "No global IPv6 detected") : snapshot.local.ipv6)
            localRow("DNS", value: snapshot.local.dnsServers.isEmpty ? L("查不到（resolver #1 未提供 nameserver）", "Unavailable (resolver #1 provided no nameserver)") : snapshot.local.dnsServers.joined(separator: ", "))
            if !snapshot.local.wifiName.isEmpty { localRow("Wi-Fi", value: snapshot.local.wifiName) }
            if !snapshot.local.tailscaleIP.isEmpty { localRow("Tailscale", value: snapshot.local.tailscaleIP) }
            if let down = snapshot.local.downloadBPS, let up = snapshot.local.uploadBPS {
                localRow(L("实时速率", "Live rate"), value: "↓ \(formatRate(down))  ↑ \(formatRate(up))")
            } else { localRow(L("实时速率", "Live rate"), value: L("查不到（采样不足或接口计数器不可用）", "Unavailable (insufficient samples or interface counters)")) }
        }
    }

    private func localRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2).help(value)
        }
    }

    private var leakSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("IPv6").font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
                Text(snapshot.leak.ipv6Message + (snapshot.leak.ipv6Country.isEmpty ? "" : " · \(snapshot.leak.ipv6Country)"))
                    .font(.system(size: 9)).foregroundColor(snapshot.leak.ipv6Blocked == false ? .orange : .secondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                Text("DNS").font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
                Text(snapshot.leak.dnsVerdict.localizedDescription).font(.system(size: 9)).foregroundColor(snapshot.leak.dnsVerdict == .domesticWarning ? .orange : .secondary)
            }
        }
    }

    private func formatRate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
}
