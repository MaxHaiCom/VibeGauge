import Cocoa
import SwiftUI

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
        VStack(alignment: .leading, spacing: 11) {
            // 1. 物理内存图表
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("物理内存")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "已用 %.1f / %.1f GB", report.usedMemoryGB, report.totalMemoryGB))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                    
                    Text("\(report.freePercentage)% 可用")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(report.freePercentage >= 60 ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                        .foregroundColor(report.freePercentage >= 60 ? .green : .orange)
                        .cornerRadius(4)
                }
                
                // 内存使用率图表进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        
                        let usedRatio = max(0.02, min(1.0, 1.0 - Double(report.freePercentage) / 100.0))
                        RoundedRectangle(cornerRadius: 3)
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
                    Spacer()
                    Text("发热 \(report.thermalStateString)")
                }
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.secondary)
            }
            
            Divider().opacity(0.5)
            
            // 2. 主流大模型运行态矩阵 (自动感知接入)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("大模型运行态 (自动感知)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    let activeCount = report.detectedLLMs.filter { $0.isRunning }.count
                    Text("\(activeCount) 个运行中")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                // 模型卡片流
                VStack(spacing: 4) {
                    ForEach(report.detectedLLMs) { llm in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                            
                            Text(llm.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(llm.isRunning ? .primary : .secondary)
                            
                            Text(llm.provider)
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text(llm.detail)
                                .font(.system(size: 9.5))
                                .foregroundColor(llm.isRunning ? .secondary : .secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(llm.isRunning ? Color.secondary.opacity(0.06) : Color.clear)
                        .cornerRadius(5)
                    }
                }
            }
            
            Divider().opacity(0.5)
            
            // 3. AI Token 与 Prompt Cache 遥测
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AI Token 与 Prompt Cache")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !report.tokens.latestModel.isEmpty {
                        Text(report.tokens.latestModel)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(3)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 实时最新一轮交互
                if report.tokens.latestContext > 0 {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最新交互 (\(report.tokens.latestSecondsAgo > 60 ? "\(report.tokens.latestSecondsAgo / 60)分钟前" : "刚刚"))")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            Text("上下文 \(formatTokensInt(report.tokens.latestContext)) · 输出 \(formatTokensInt(report.tokens.latestOutput))")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f%% 命中", report.tokens.latestCacheHitRate))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                            if report.tokens.latestThinking > 0 {
                                Text("思考 \(formatTokensInt(report.tokens.latestThinking))")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(7)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
                
                // 今日累计上下文与缓存进度条
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("今日总上下文: \(formatTokens(report.tokens.todayContext))")
                            .font(.system(size: 10.5, weight: .medium))
                        Spacer()
                        Text(String(format: "缓存率 %.1f%%", report.tokens.todayCacheHitRate))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(report.tokens.todayCacheHitRate >= 80 ? .green : .secondary)
                    }
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(height: 5)
                            
                            let hitRatio = max(0.01, min(1.0, report.tokens.todayCacheHitRate / 100.0))
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.green.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(hitRatio), height: 5)
                        }
                    }
                    .frame(height: 5)
                    
                    HStack {
                        Text("输出 \(formatTokens(report.tokens.todayOutput)) (思考 \(formatTokens(report.tokens.todayThinking)))")
                        Spacer()
                        Text("5h周期: \(report.tokens.turns5h)轮 · \(formatTokens(report.tokens.context5h))")
                    }
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                }
                .padding(.top, 1)
            }
            
            Divider().opacity(0.5)
            
            // 4. 磁盘与 MCP 负载
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    let mcpMemStr = report.activeMCPTotalMemMB > 1024
                        ? String(format: "%.1f GB", report.activeMCPTotalMemMB / 1024.0)
                        : "\(Int(report.activeMCPTotalMemMB)) MB"
                    Text("MCP: \(report.activeMCPProcessCount)个进程 (\(mcpMemStr))")
                    Spacer()
                    let npxStr = report.npxCacheMB > 1024
                        ? String(format: "%.1f GB", report.npxCacheMB / 1024.0)
                        : "\(Int(report.npxCacheMB)) MB"
                    Text("NPX 缓存: \(npxStr)")
                }
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                
                HStack {
                    Text(String(format: "系统主磁盘: 剩余 %.1f GB (%.0f%%)", report.diskFreeGB, report.diskFreePct))
                    Spacer()
                    Text(String(format: "CPU 负载: %.2f", report.loadAvg1m))
                }
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
            }
            
            // 5. 清理触发区
            if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
                Divider().opacity(0.5)
                
                VStack(spacing: 5) {
                    if report.totalOrphanCount > 0 {
                        Button(action: onCleanOrphans) {
                            HStack {
                                Text("清理断链 AI 残留进程")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                let memStr = report.totalOrphanMemMB > 1024
                                    ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                                    : "\(Int(report.totalOrphanMemMB)) MB"
                                Text(memStr)
                                    .font(.system(size: 10, weight: .bold))
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
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                let npxStr = report.npxCacheMB > 1024
                                    ? String(format: "%.2f GB", report.npxCacheMB / 1024.0)
                                    : "\(Int(report.npxCacheMB)) MB"
                                Text(npxStr)
                                    .font(.system(size: 10, weight: .semibold))
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
    }
}
