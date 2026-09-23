import Foundation

// MARK: - 数据模型

/// 一个候选孤儿进程：带完整命令行，供杀之前核对与在面板上预览
public struct OrphanProc: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cmd: String
    public let memMB: Double
    public let service: String
}

/// 被规则放过的进程 + 放过的原因（面板上要能说清"为什么没动它"）
public struct ProtectedProc: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cmd: String
    public let memMB: Double
    public let reason: String
}

public struct ServiceGroup: Identifiable {
    public var id: String { serviceName }
    public let serviceName: String
    public var processCount: Int
    public var totalMemMB: Double
    public var pids: [Int]
}

/// 一次 API 调用（同一 requestId 在 jsonl 里会写多行，按 requestId 去重后才是"一轮"）
public struct InteractionRecord: Identifiable, Equatable {
    public var id: String
    public var model: String
    public var timestamp: TimeInterval
    public var contextTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int

    public var cacheHitRate: Double {
        contextTokens > 0 ? Double(cacheReadTokens) / Double(contextTokens) * 100.0 : 0.0
    }
}

/// 今日消耗按项目（工作目录）归因
public struct ProjectUsage: Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public var turns: Int = 0
    public var ctx: Int64 = 0
    public var out: Int64 = 0
    public var think: Int64 = 0
    public var clis: [String] = []          // 哪些 CLI 在这个目录里干过活
    /// 末级目录名，面板上显示用
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

public struct TokenStats: Equatable {
    /// 最近 3 轮（跨所有会话，按时间倒序）
    public var recentInteractions: [InteractionRecord] = []

    /// 今日 = 本地日历日（按每轮 timestamp 归类，不按文件 mtime）
    public var todayTurns: Int = 0
    public var todayContext: Int64 = 0
    public var todayCacheRead: Int64 = 0
    public var todayOutput: Int64 = 0
    public var todayThinking: Int64 = 0
    public var todayCacheHitRate: Double {
        todayContext > 0 ? Double(todayCacheRead) / Double(todayContext) * 100.0 : 0.0
    }

    /// 今日按项目归因（按上下文 token 降序）
    public var todayByProject: [ProjectUsage] = []
    /// 今日 Claude Code 请求异常（本地日志里的错误事件，只存类型和时间）
    public var anomalies = RequestAnomalies()
}

/// 请求异常：最终失败（用户看到的错误回复）与自动重试分开计，一次故障重试 5 次不算 5 次失败
public struct RequestAnomalies: Equatable {
    public enum Kind: String, CaseIterable { case rateLimit, overloaded, server, auth, connection, other }
    public var failures: [Kind: Int] = [:]
    public var retries: [Kind: Int] = [:]
    public var lastAt: TimeInterval? = nil
    public var isEmpty: Bool { failures.isEmpty && retries.isEmpty }

    public static func label(_ k: Kind) -> String {
        switch k {
        case .rateLimit: return L("限流", "rate-limited")
        case .overloaded: return L("过载", "overloaded")
        case .server: return L("服务端", "server")
        case .auth: return L("认证", "auth")
        case .connection: return L("连接", "connection")
        case .other: return L("其他", "other")
        }
    }
    /// 「限流 1 · 服务端 3」，按次数从多到少
    public static func text(_ m: [Kind: Int]) -> String {
        m.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { "\(label($0.key)) \($0.value)" }.joined(separator: " · ")
    }
}

/// 某个 CLI 今日自己的用量（各家日志能给多少就给多少，给不了的说明原因）
public struct CLIUsage: Identifiable {
    public var id: String { name }
    public let name: String
    public var requests: Int = 0
    public var ctx: Int64 = 0
    public var cacheRead: Int64 = 0
    public var out: Int64 = 0
    public var think: Int64 = 0
    public var turns: Int = 0
    public var note: String = ""          // 非空 = 本地拿不到 token，只能给这句说明
    public var hasTokens: Bool { ctx > 0 || out > 0 }
    public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100.0 : 0.0 }
}

public struct SubQuota: Identifiable {
    public var id: String { name }
    public let name: String
    public let window: QuotaWindow
    public init(name: String, window: QuotaWindow) {
        self.name = name
        self.window = window
    }
}

/// 一个活跃 CLI 会话（详情页列出来：在哪个目录、跑了多久）
public struct SessionInfo: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cwd: String
    public let startedAgo: Int      // 秒
    public let memMB: Double
}

/// 详情页用的补充信息：平台级的订阅/账号/来源字段（只放本地文件里真实存在的，邮箱类一律不取）
public struct PlatformDetail {
    public var rows: [(String, String)] = []        // 展示用键值对
    public var sessions: [SessionInfo] = []
    public var sourceFiles: [String] = []           // 数据来自哪些文件
    public var extraPools: [(String, QuotaWindow)] = []   // 主卡没显示的桶（如 Codex Spark）
}

public struct DetectedLLMRuntime: Identifiable {
    /// 身份默认就是名字；API 卡片用卡片 ID（同名的两个账户不能撞）
    public var cardID: String = ""
    public var id: String { cardID.isEmpty ? name : cardID }
    public let name: String
    public let isRunning: Bool
    public let tier: String
    public let detail: String
    public var fiveHour: QuotaWindow? = nil
    public var sevenDay: QuotaWindow? = nil
    /// 月窗口（Coding Plan 类套餐有 5h / 周 / 月三层）
    public var monthly: QuotaWindow? = nil
    public var secondaryPoolName: String = ""
    public var secondaryFiveHour: QuotaWindow? = nil
    public var secondarySevenDay: QuotaWindow? = nil
    public var isFullWidth: Bool = false
    public var quotaSubtitle: String = ""
    /// 没额度数据、且可以一键接上状态栏桥接时 = "claude" / "agy"（卡片上显示「一键连接」）
    public var connectTool: String = ""
    /// 卡片第三行附加信息（API Key 卡片用：模型 + 今日 token）
    public var extraLine: String = ""
    /// 卡片第四行（API Key 卡片用：p95 延迟 / 错误率 / 花费）
    public var extraLine2: String = ""
    /// 额度条下方的口径说明（如"估算 · 本机记账 213 次 / 1200"）—— 估出来的数必须标明
    public var quotaNote: String = ""
    /// 一个套餐带多个模型各自额度（如 OpenCode Zen）：卡内只显示用得最紧的 3 个，其余折叠
    public var subQuotas: [SubQuota] = []

    public var platformDetail: PlatformDetail = PlatformDetail()

    public var hasQuota: Bool { fiveHour != nil || sevenDay != nil || monthly != nil || secondaryFiveHour != nil || secondarySevenDay != nil }
}

/// 一个 API Key（只存代理写下的 SHA-256 前 8 位指纹，永不落明文）今日的用量
public struct APIKeyUsage: Identifiable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public var calls: Int = 0
    public var errors: Int = 0
    public var ctx: Int64 = 0
    public var out: Int64 = 0
    public var lastTS: TimeInterval = 0
    public var cost: Double? = nil
    public var models: [String] = []
}

/// 经记账代理的某个上游：今日调用汇总 + 额度/余额
public struct APIProviderStatus: Identifiable {
    /// 卡片身份 = 上游 host + 服务路由（provider 名里已带，如火山 Coding / 按量）+ 账户（同一上游出现多个 key 才拆）
    public var cardID: String = ""
    public var id: String { cardID.isEmpty ? host : cardID }
    public let host: String
    public let provider: String
    /// 这张卡对应的 key 指纹（"-" = 没带 key）。卡片 ID 里总有它：同一路由后来多出一个 key，已有卡的 ID 也不变
    public var account: String = ""
    /// 同一路由出现过多个 key → 标题带指纹区分；只有一个 key 时标题就是上游名
    public var showsAccount = false
    public var displayName: String { showsAccount ? "\(provider) · \(account == "-" ? L("无 key", "no key") : String(account.prefix(8)))" : provider }
    public var calls: Int = 0
    public var errors: Int = 0
    public var ctx: Int64 = 0
    public var cacheRead: Int64 = 0
    public var out: Int64 = 0
    public var think: Int64 = 0
    public var lastTS: TimeInterval = 0
    public var models: [String] = []
    public var plan: String = ""
    /// 订阅套餐（plans.json 配了，或厂商用量接口返回了套餐）：放订阅页；否则是按量 API key，放 API 页
    public var isSubscription = false
    public var fiveHour: QuotaWindow? = nil
    public var sevenDay: QuotaWindow? = nil
    public var monthly: QuotaWindow? = nil
    /// 从最近一次调用的限流响应头解析出来的余量（被动，不额外发请求）
    public var headerWindow: QuotaWindow? = nil
    public var headerLabel: String = ""
    /// 额度是「本机记账的请求数 ÷ 套餐上限」估的（订阅制 Coding Plan 没有公开用量接口）
    public var quotaIsEstimate: Bool = false
    /// 估算的底数，要显示给用户看清这数怎么来的："本机记账 213 次 / 1200"
    public var estimateNote: String = ""
    public var planLimitText: String = ""
    /// 套餐里有独立额度的模型（plans.json 的 models）：每个模型一条
    public var subQuotas: [SubQuota] = []
    public var balanceText: String = ""
    public var quotaError: String = ""
    /// 额度是厂商官方给的：从哪来（「官方用量接口」「官方 CLI · arkcli」）；空 = 没有官方来源
    public var quotaSource: String = ""
    public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100.0 : 0.0 }

    // 可观测性（全部由 api-calls.jsonl 里已有的 status/ms/key 字段算出）
    public var p50ms: Int = 0
    public var p95ms: Int = 0
    public var maxms: Int = 0
    public var count429: Int = 0
    /// 成功但用量未知的调用次数：token 合计里没有它们，面板要说出来，不能装作用了 0
    public var unknownUsage: Int = 0
    /// nil = 没配价目表，不估（不编价格）
    public var cost: Double? = nil
    public var costCurrency: String = ""
    public var keys: [APIKeyUsage] = []
    public var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) * 100.0 : 0.0 }
}

/// 记账覆盖体检：shell 配置里的 *_BASE_URL 有几处走了代理、几处没走。
/// 没走的那些 = 面板上看不到的调用（账上的窟窿）。只取变量名与主机名，绝不碰同一行里的 key。
public struct ProxyCoverage {
    public struct Entry: Identifiable {
        public var id: String { "\(file):\(line):\(name)" }
        public let name: String        // 变量名，如 ANTHROPIC_BASE_URL
        public let host: String        // 上游主机
        public let file: String        // 哪个 rc 文件
        public let line: Int
        public let proxied: Bool
    }
    public var entries: [Entry] = []
    public var proxiedCount: Int { entries.filter { $0.proxied }.count }
    public var directCount: Int { entries.filter { !$0.proxied }.count }
}

public struct ProxyStatus {
    public var installed: Bool = false
    public var coverage: ProxyCoverage = ProxyCoverage()
    /// 价目表状态（没配就别在界面上编花费）
    public var hasPriceTable: Bool = false
    public var priceAsOf: String = ""

    public var running: Bool = false
    public var port: Int = 18790
    public var callsSinceStart: Int = 0
    public var providers: [APIProviderStatus] = []
}

/// 一块占盘的目录。`purgeable` = 允许按年龄清理（只有会话日志与包缓存属于这类）；
/// 其余（sqlite 运行库、插件、技能、生成的图片）一律只报不动 —— 删了会弄坏工具或丢掉用户资产。
public struct DiskItem: Identifiable {
    public var id: String { path }
    public let path: String
    public let label: String
    public var totalMB: Double = 0
    public var files: Int = 0
    public var oldMB: Double = 0          // 超过保留天数的部分
    public var oldFiles: Int = 0
    public var purgeable: Bool = false
    public var note: String = ""          // 清了会失去什么 / 为什么不清
}

public struct ScanReport {
    // 内存与虚拟内存
    public var freePercentage: Int = 0
    public var totalMemoryGB: Double = 0.0
    public var usedMemoryGB: Double = 0.0
    public var swapUsedGB: Double = 0.0
    public var compressorGB: Double = 0.0

    // 硬件与发热负载
    public var thermalStateString: String = L("正常", "Normal")
    public var loadAvg1m: Double = 0.0
    public var loadAvg5m: Double = 0.0
    public var diskFreeGB: Double = 0.0
    public var diskTotalGB: Double = 0.0
    public var diskFreePct: Double = 0.0

    // 各平台运行时 + 档位 + 额度
    public var detectedLLMs: [DetectedLLMRuntime] = []

    public var activeMCPProcessCount: Int = 0
    public var activeMCPTotalMemMB: Double = 0.0

    public var tokens: TokenStats = TokenStats()
    public var npxCacheMB: Double = 0.0

    // 磁盘占用（会话日志治理）
    public var disk: [DiskItem] = []
    public var diskTotalAIGB: Double = 0.0
    public var purgeableMB: Double { disk.filter { $0.purgeable }.reduce(0) { $0 + $1.oldMB } }

    // 各 CLI 今日自己的用量
    public var cliUsage: [CLIUsage] = []
    /// 近期活跃会话的上下文水位与压缩记录
    public var sessions: [SessionContext] = []
    /// 在等你批准 / 输入的会话（需开启「待处理会话」Hook）
    public var pending: [PendingSession] = []

    // API Key 调用（记账代理）
    public var api: ProxyStatus = ProxyStatus()

    // 断链孤儿
    public var orphanedGroups: [ServiceGroup] = []
    public var orphans: [OrphanProc] = []
    public var protected: [ProtectedProc] = []
    public var allOrphanPids: [Int] = []
    public var totalOrphanCount: Int = 0
    public var totalOrphanMemMB: Double = 0.0
}
