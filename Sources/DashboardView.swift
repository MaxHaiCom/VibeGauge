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
    
    private var cliSummaryText: String {
        var arr: [String] = []
        if report.activeClaudeCount > 0 { arr.append("Claude (\(report.activeClaudeCount))") }
        if report.activeAgyCount > 0 { arr.append("Agy (\(report.activeAgyCount))") }
        return arr.isEmpty ? "无活跃会话" : arr.joined(separator: " · ")
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 1. 物理内存图表
            VStack(alignment: .leading, spacing: 6) {
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
                            .frame(height: 6)
                        
                        let usedRatio = max(0.02, min(1.0, 1.0 - Double(report.freePercentage) / 100.0))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(report.freePercentage >= 60 ? Color.green : Color.orange)
                            .frame(width: geo.size.width * CGFloat(usedRatio), height: 6)
                    }
                }
                .frame(height: 6)
                
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
            
            Divider()
                .opacity(0.6)
            
            // 2. Vibe Coding AI 会话负载看板
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 编程环境")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    // 卡片 1: 活动终端
                    VStack(alignment: .leading, spacing: 3) {
                        Text("活动终端会话")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text(cliSummaryText)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                    
                    // 卡片 2: MCP 负载
                    VStack(alignment: .leading, spacing: 3) {
                        Text("挂载 MCP 进程")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        let mcpMemStr = report.activeMCPTotalMemMB > 1024
                            ? String(format: "%.1f GB", report.activeMCPTotalMemMB / 1024.0)
                            : "\(Int(report.activeMCPTotalMemMB)) MB"
                        
                        Text("\(report.activeMCPProcessCount) 个 · \(mcpMemStr)")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }
            
            Divider()
                .opacity(0.6)
            
            // 3. 磁盘与硬件算力
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("系统主磁盘")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "剩余 %.1f GB (%.0f%%)", report.diskFreeGB, report.diskFreePct))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
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
                    Text(String(format: "CPU 负载: %.2f", report.loadAvg1m))
                    Spacer()
                    let npxStr = report.npxCacheMB > 1024
                        ? String(format: "%.1f GB", report.npxCacheMB / 1024.0)
                        : "\(Int(report.npxCacheMB)) MB"
                    Text("NPX 缓存: \(npxStr)")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            
            // 4. 清理触发区 (卡片式高亮操作按钮)
            if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
                Divider()
                    .opacity(0.6)
                
                VStack(spacing: 6) {
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
                            .padding(.vertical, 7)
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
                            .padding(.vertical, 7)
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
        .frame(width: 300)
    }
}
