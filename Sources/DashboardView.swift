import Cocoa
import SwiftUI

struct MiniProgressBar: View {
    var value: Double
    var color: Color = .green
    var width: CGFloat = 16
    var height: CGFloat = 3.5
    
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: width, height: height)
            
            let safeRatio = max(0.02, min(1.0, value))
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: max(1.5, width * CGFloat(safeRatio)), height: height)
        }
    }
}

public struct DashboardView: View {
    public var report: ScanReport
    public var onCleanOrphans: () -> Void
    public var onCleanNPX: () -> Void
    
    public init(
        report: ScanReport,
        onCleanOrphans: @escaping () -> Void,
        onCleanNPX: @escaping () -> Void
    ) {
        self.report = report
        self.onCleanOrphans = onCleanOrphans
        self.onCleanNPX = onCleanNPX
    }
    
    private func tierBackgroundColor(_ tier: String) -> Color {
        if tier.contains("API") { return Color.blue.opacity(0.18) }
        if tier.contains("本地") { return Color.purple.opacity(0.18) }
        if tier.contains("Max") || tier.contains("Plus") || tier.contains("Pro") || tier.contains("5x") || tier.contains("Premium") || tier.contains("SuperGrok") { return Color.green.opacity(0.18) }
        return Color.teal.opacity(0.18)
    }
    
    private func tierForegroundColor(_ tier: String) -> Color {
        if tier.contains("API") { return Color.blue }
        if tier.contains("本地") { return Color.purple }
        if tier.contains("Max") || tier.contains("Plus") || tier.contains("Pro") || tier.contains("5x") || tier.contains("Premium") || tier.contains("SuperGrok") { return Color.green }
        return Color.teal
    }
    
    private struct ModelDisplayGroup: Identifiable {
        let id: String
        let isFullWidth: Bool
        let models: [DetectedLLMRuntime]
    }
    
    private var modelDisplayGroups: [ModelDisplayGroup] {
        var groups: [ModelDisplayGroup] = []
        var currentRegular: [DetectedLLMRuntime] = []
        
        for llm in report.detectedLLMs {
            if llm.isFullWidth {
                if !currentRegular.isEmpty {
                    groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
                    currentRegular = []
                }
                groups.append(ModelDisplayGroup(id: "full-\(llm.id)", isFullWidth: true, models: [llm]))
            } else {
                currentRegular.append(llm)
            }
        }
        if !currentRegular.isEmpty {
            groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
        }
        return groups
    }
    
    private func formatTokens(_ count: Int64) -> String {
        if count >= 100_000_000 {
            return String(format: "%.2f 亿", Double(count) / 100_000_000.0)
        } else if count >= 10_000 {
            return String(format: "%.1f 万", Double(count) / 10_000.0)
        } else {
            return "\(count)"
        }
    }
    
    private func formatTokensInt(_ count: Int) -> String {
        formatTokens(Int64(count))
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            
            // ==========================================
            // 模块 1: 物理与系统硬件 (Hardware Layer)
            // ==========================================
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("系统物理硬件")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("发热: \(report.thermalStateString)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(report.thermalStateString == "正常" ? .secondary : .orange)
                }
                
                // 1.1 物理内存
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("内存")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(String(format: "已用 %.1f / %.1f GB", report.usedMemoryGB, report.totalMemoryGB))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Text("\(report.freePercentage)% 可用")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(report.freePercentage >= 60 ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                            .foregroundColor(report.freePercentage >= 60 ? .green : .orange)
                            .cornerRadius(3)
                    }
                    
                    // 内存进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(height: 5)
                            let usedRatio = max(0.02, min(1.0, 1.0 - Double(report.freePercentage) / 100.0))
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(report.freePercentage >= 60 ? Color.green : Color.orange)
                                .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                        }
                    }
                    .frame(height: 5)
                    
                    HStack(spacing: 4) {
                        let compStr = report.compressorGB > 1.0
                            ? String(format: "%.2f GB", report.compressorGB)
                            : "\(Int(report.compressorGB * 1024)) MB"
                        let swapStr = report.swapUsedGB > 1.0
                            ? String(format: "%.2f GB", report.swapUsedGB)
                            : "\(Int(report.swapUsedGB * 1024)) MB"
                        Text("压缩池 \(compStr)")
                        Text("·")
                        Text("Swap \(swapStr)")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }
                
                // 1.2 系统磁盘
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("磁盘")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(String(format: "剩余 %.1f GB / %.1f GB (%.0f%%)", report.diskFreeGB, report.diskTotalGB, report.diskFreePct))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    // 磁盘进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(height: 5)
                            let usedRatio = report.diskTotalGB > 0 ? max(0.02, min(1.0, (report.diskTotalGB - report.diskFreeGB) / report.diskTotalGB)) : 0.5
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.blue.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                        }
                    }
                    .frame(height: 5)
                    
                    HStack {
                        Text(String(format: "CPU 负载: %.2f (1m)", report.loadAvg1m))
                        Spacer()
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            
            // ==========================================
            // 模块 2: AI 大模型与编程环境 (AI Layer)
            // ==========================================
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI 运行与大模型")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    let activeCount = report.detectedLLMs.filter { $0.isRunning }.count
                    HStack(spacing: 4) {
                        Circle()
                            .fill(activeCount > 0 ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                        Text("\(activeCount) 个平台活跃")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // 2.1 主流大模型运行状态矩阵 (普通卡片双列，Gemini 等多额度池模型独占单列通栏)
                let gridCols = [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ]
                
                VStack(spacing: 5) {
                    ForEach(modelDisplayGroups) { group in
                        if group.isFullWidth {
                            if let model = group.models.first {
                                fullWidthModelCard(for: model)
                            }
                        } else {
                            LazyVGrid(columns: gridCols, spacing: 5) {
                                ForEach(group.models) { llm in
                                    modelCard(for: llm)
                                }
                            }
                        }
                    }
                }
                
                Divider().opacity(0.35)
                
                // 2.2 Token 消耗与 Prompt Cache 效益 (精致仪表盘)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("今日上下文")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(formatTokens(report.tokens.todayContext))
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "缓存率 %.1f%%", report.tokens.todayCacheHitRate))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(report.tokens.todayCacheHitRate >= 80 ? .green : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(report.tokens.todayCacheHitRate >= 80 ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                            .cornerRadius(3)
                    }
                    
                    // Prompt Cache 命中率对比进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(height: 4)
                            let hitRatio = max(0.01, min(1.0, report.tokens.todayCacheHitRate / 100.0))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(hitRatio), height: 4)
                        }
                    }
                    .frame(height: 4)
                    
                    HStack {
                        Text("总生成 \(formatTokens(report.tokens.todayOutput)) (思考 \(formatTokens(report.tokens.todayThinking)))")
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("今日交互: \(report.tokens.todayTurns) 轮")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // 2.3 最新交互遥测
                if report.tokens.latestContext > 0 {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("最新交互")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("·")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                Text(report.tokens.latestModel.isEmpty ? "AI" : report.tokens.latestModel)
                                    .font(.system(size: 8.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Text(report.tokens.latestSecondsAgo > 60 ? "(\(report.tokens.latestSecondsAgo / 60)分钟前)" : "(刚刚)")
                                    .font(.system(size: 8.5))
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("上下文 \(formatTokensInt(report.tokens.latestContext))")
                                Text("·")
                                Text("输出 \(formatTokensInt(report.tokens.latestOutput))")
                            }
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.1f%%", report.tokens.latestCacheHitRate))
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(report.tokens.latestCacheHitRate >= 80 ? .green : .primary)
                            Text("缓存命中")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
                
                Divider().opacity(0.35)
                
                // 2.4 MCP 与开发缓存概况
                HStack {
                    let mcpMemStr = report.activeMCPTotalMemMB > 1024
                        ? String(format: "%.1f GB", report.activeMCPTotalMemMB / 1024.0)
                        : "\(Int(report.activeMCPTotalMemMB)) MB"
                    HStack(spacing: 3) {
                        Text("MCP:")
                            .foregroundColor(.secondary)
                        Text("\(report.activeMCPProcessCount) 进程 (\(mcpMemStr))")
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    let npxStr = report.npxCacheMB > 1024
                        ? String(format: "%.1f GB", report.npxCacheMB / 1024.0)
                        : "\(Int(report.npxCacheMB)) MB"
                    HStack(spacing: 3) {
                        Text("NPX 缓存:")
                            .foregroundColor(.secondary)
                        Text(npxStr)
                            .foregroundColor(.primary)
                    }
                }
                .font(.system(size: 9))
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            
            // ==========================================
            // 模块 3: 清理与维护操作 (Action Layer)
            // ==========================================
            if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
                VStack(spacing: 5) {
                    if report.totalOrphanCount > 0 {
                        Button(action: onCleanOrphans) {
                            HStack {
                                Text("清理断链 AI 残留进程")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                let memStr = report.totalOrphanMemMB > 1024
                                    ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                                    : "\(Int(report.totalOrphanMemMB)) MB"
                                Text(memStr)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if report.npxCacheMB > 100 {
                        Button(action: onCleanNPX) {
                            HStack {
                                Text("清理 NPX 临时工具缓存")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                let npxStr = report.npxCacheMB > 1024
                                    ? String(format: "%.2f GB", report.npxCacheMB / 1024.0)
                                    : "\(Int(report.npxCacheMB)) MB"
                                Text(npxStr)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("AI 与系统运行环境健康，暂无残留垃圾")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320)
    }
    
    // 普通卡片 (双列)
    @ViewBuilder
    private func modelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            // Row 1: 状态指示点 + 模型名 + 档位标 + 状态
            HStack(spacing: 3.5) {
                Circle()
                    .fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
                
                Text(llm.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(llm.isRunning ? .primary : .secondary)
                    .lineLimit(1)
                
                if !llm.tier.isEmpty {
                    Text(llm.tier)
                        .font(.system(size: 7.5, weight: .bold))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(tierBackgroundColor(llm.tier))
                        .foregroundColor(tierForegroundColor(llm.tier))
                        .cornerRadius(2.5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                
                Spacer(minLength: 2)
                
                Text(llm.detail)
                    .font(.system(size: 8.5))
                    .foregroundColor(llm.isRunning ? .secondary : .secondary.opacity(0.5))
                    .lineLimit(1)
            }
            
            // Row 2: 专属额度用量条 (在百分比前放置微型进度条)
            if let fh = llm.fiveHourPct {
                HStack(spacing: 3) {
                    Text("5H")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundColor(.secondary)
                    MiniProgressBar(value: Double(fh) / 100.0, color: fh > 80 ? .orange : .green, width: 16, height: 3.5)
                    Text("\(fh)%")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(fh > 80 ? .orange : .primary)
                    
                    if let sd = llm.sevenDayPct {
                        Text("·")
                            .font(.system(size: 7))
                            .foregroundColor(.secondary)
                        Text("W")
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(.secondary)
                        MiniProgressBar(value: Double(sd) / 100.0, color: sd > 80 ? .orange : .green, width: 16, height: 3.5)
                        Text("\(sd)%")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(sd > 80 ? .orange : .primary)
                    }
                }
            } else {
                Text(llm.quotaSubtitle.isEmpty ? (llm.isRunning ? "服务就绪" : "未启动") : llm.quotaSubtitle)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(llm.isRunning ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.03))
        .cornerRadius(6)
    }
    
    // 全宽卡片 (支持 Gemini 复合多额度池：原生池 + Claude/GPT 三方池)
    @ViewBuilder
    private func fullWidthModelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            // Row 1: 标题 + 档位标 + 会话数
            HStack(spacing: 4) {
                Circle()
                    .fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
                
                Text(llm.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(llm.isRunning ? .primary : .secondary)
                
                if !llm.tier.isEmpty {
                    Text(llm.tier)
                        .font(.system(size: 7.5, weight: .bold))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(tierBackgroundColor(llm.tier))
                        .foregroundColor(tierForegroundColor(llm.tier))
                        .cornerRadius(2.5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                
                Spacer()
                
                Text(llm.detail)
                    .font(.system(size: 8.5))
                    .foregroundColor(llm.isRunning ? .secondary : .secondary.opacity(0.5))
            }
            
            // Row 2: 复合双额度池 (原生池 + Claude/GPT 三方池并排)
            HStack(spacing: 6) {
                // 5H 与 W (直接展示，不加任何“原生”前缀)
                HStack(spacing: 3.5) {
                    if let fh = llm.fiveHourPct {
                        Text("5H")
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(.secondary)
                        MiniProgressBar(value: Double(fh) / 100.0, color: fh > 80 ? .orange : .green, width: 16, height: 3.5)
                        Text("\(fh)%")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(fh > 80 ? .orange : .primary)
                    }
                    
                    if let sd = llm.sevenDayPct {
                        Text("·")
                            .font(.system(size: 7))
                            .foregroundColor(.secondary)
                        Text("W")
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(.secondary)
                        MiniProgressBar(value: Double(sd) / 100.0, color: sd > 80 ? .orange : .green, width: 16, height: 3.5)
                        Text("\(sd)%")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(sd > 80 ? .orange : .primary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(4)
                
                Spacer()
                
                // 三方聚合池 (Claude + GPT)
                if let tpW = llm.secondarySevenDayPct {
                    HStack(spacing: 3) {
                        Text("三方")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Text("W")
                            .font(.system(size: 7.5))
                            .foregroundColor(.secondary)
                        MiniProgressBar(value: Double(tpW) / 100.0, color: tpW >= 100 ? .red : (tpW > 80 ? .orange : .green), width: 16, height: 3.5)
                        Text("\(tpW)%")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(tpW >= 100 ? .red : (tpW > 80 ? .orange : .primary))
                        
                        if tpW >= 100 {
                            Text("耗尽")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(.red.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(4)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(llm.isRunning ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.03))
        .cornerRadius(6)
    }
}
