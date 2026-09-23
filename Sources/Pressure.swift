import Foundation

// MARK: - 压力信号（菜单栏图标 + 阈值通知共用，纯计算可自测）

/// 一条统一方向的"压力"信号：pct 越大越紧张。
/// 额度本来就是"已用 %"；内存/磁盘取"已用 %"后与额度同向，可放在一起比。
public struct PressureSignal: Identifiable, Equatable {
    public enum Kind: Equatable { case quota, memory, disk }

    /// 去重键：通知状态按它记。额度键里带重置点，换窗口后自然是新键，能再报一次
    public let key: String
    public let short: String        // 短名，进图标旁的文字与通知标题
    public let pct: Int
    public let detail: String       // 通知正文
    public let kind: Kind

    public var id: String { key }

    /// 各信号自己的报警线：内存 85% 已用才算紧，磁盘要到 90%，额度 80% 就该收手
    public var warn: Int {
        switch kind {
        case .quota: return 80
        case .memory: return 85
        case .disk: return 90
        }
    }
    public var crit: Int {
        switch kind {
        case .quota: return 95
        case .memory: return 93
        case .disk: return 96
        }
    }
    /// 0 = 正常，1 = 警告，2 = 危急
    public var level: Int { pct >= crit ? 2 : (pct >= warn ? 1 : 0) }
    /// 离自己报警线还差多少（正数 = 已越线）。排序按它，而不是按 pct，
    /// 否则"内存已用 60%"会永远压住"额度已用 55%"，而后者其实更该被看见
    public var margin: Int { pct - warn }
}

public extension ScanReport {
    /// 全部压力信号，按"离各自报警线的距离"倒序。没数据的额度窗口不参与（不编）
    var pressures: [PressureSignal] {
        var out: [PressureSignal] = []

        func addQuota(_ w: QuotaWindow?, _ platform: String, _ pool: String, keyPool: String? = nil, keyID: String? = nil) {
            guard let w = w else { return }
            let pct = w.effectivePct()
            var detail = L("已用 \(pct)%", "\(pct)% used")
            if let r = w.resetText() { detail += " · " + r }
            // 去重键只认「哪个池」，不带重置时间：agy 等按「现在 + 剩余秒数」算重置点，每次刷新都差几秒，
            // 带进键里会让同一个满额池隔几分钟就当成新周期再报一遍。新周期靠用量回落到警告线以下自然重新布防
            out.append(PressureSignal(key: "quota:\(keyID ?? platform):\(keyPool ?? pool)",
                                      short: "\(platform) \(pool)", pct: pct, detail: detail, kind: .quota))
        }

        for l in detectedLLMs {
            addQuota(l.fiveHour, l.name, "5h")
            addQuota(l.sevenDay, l.name, L("周", "weekly"), keyPool: "周")
            let sec = l.secondaryPoolName.isEmpty ? L("副池", "Secondary") : (l.secondaryPoolName == "三方" ? L("三方", "3P") : l.secondaryPoolName)
            let secKey = l.secondaryPoolName.isEmpty ? "副池" : l.secondaryPoolName
            addQuota(l.secondaryFiveHour, l.name, "\(sec) 5h", keyPool: "\(secKey) 5h")
            addQuota(l.secondarySevenDay, l.name, "\(sec) \(L("周", "weekly"))", keyPool: "\(secKey) 周")
            for s in l.subQuotas { addQuota(s.window, l.name, s.name) }
        }
        for p in api.providers {
            addQuota(p.fiveHour, p.displayName, "5h", keyID: p.id)
            addQuota(p.sevenDay, p.displayName, L("周", "weekly"), keyPool: "周", keyID: p.id)
        }

        if totalMemoryGB > 0 {
            out.append(PressureSignal(key: "mem", short: L("内存", "Memory"), pct: max(0, 100 - freePercentage),
                                      detail: String(format: L("已用 %.1f / %.1f GB · swap %.2f GB", "%.1f / %.1f GB used · swap %.2f GB"),
                                                     usedMemoryGB, totalMemoryGB, swapUsedGB), kind: .memory))
        }
        if diskTotalGB > 0 {
            out.append(PressureSignal(key: "disk", short: L("磁盘", "Disk"), pct: Int((100.0 - diskFreePct).rounded()),
                                      detail: String(format: L("剩余 %.0f GB / %.0f GB", "%.0f / %.0f GB free"), diskFreeGB, diskTotalGB), kind: .disk))
        }

        // 先比等级（危急 > 警告 > 正常），同级再比离线多近：磁盘 97%（危急）不能排在额度 90%（警告）后面
        return out.sorted { ($0.level, $0.margin, $0.pct) > ($1.level, $1.margin, $1.pct) }
    }

    /// 最紧的那一条 —— 菜单栏图标画它
    var tightest: PressureSignal? { pressures.first }
}
