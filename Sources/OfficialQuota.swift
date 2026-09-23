import AppKit
import CryptoKit
import Foundation
import Security

// 不经记账代理也能拿到的官方额度：
// A. 钥匙串里登记的 API key：每 5 分钟用它查一次该厂商自己的用量 / 余额接口（复用代理脚本的 --probe，key 走 stdin）
// B. 厂商官方 CLI（火山 arkcli、阿里 bl）：用户自己装好登录后，本机运行它读订阅额度
// 两者都只在后台串行队列里跑，不占扫描锁；扫描时 snapshot() 取最近一次结果。

/// 官方 CLI 读到的订阅额度
public struct CLIQuota: Equatable {
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?
    public var monthly: QuotaWindow?
    public var plan = ""
    /// 登录了但没有订阅（阿里返回 {}；火山 items 为空）
    public var noSubscription = false
}

public enum OfficialCLI: String, CaseIterable {
    case ark, bailian

    var bin: String { self == .ark ? "arkcli" : "bl" }
    var args: [String] { self == .ark ? ["usage", "plan", "--product", "coding-plan", "--format", "json"] : ["usage", "coding-plan", "--output", "json"] }
    public var title: String { self == .ark ? L("火山方舟 Coding Plan", "Volcengine Ark Coding Plan") : L("阿里云百炼 Coding Plan", "Alibaba Model Studio Coding Plan") }
    /// 结果并到哪张订阅卡：provider 名（代理按路由起的名字）或 host 片段
    var provider: String { self == .ark ? "火山方舟 Coding" : "阿里云百炼 Coding" }
    var host: String { self == .ark ? "ark.cn-beijing.volces.com" : "coding.dashscope.aliyuncs.com" }
    func matches(_ p: APIProviderStatus) -> Bool {
        self == .ark ? p.provider == provider : (p.provider == provider || p.host.contains("coding.dashscope"))
    }
    var install: String {
        self == .ark
            ? #"""
              if ! command -v npm >/dev/null 2>&1; then
                echo "需要先安装 Node.js：https://nodejs.org 下载安装，或在终端运行 brew install node。装好后回 VibeGauge 再点一次。"
                echo "Node.js is required: install it from https://nodejs.org (or brew install node), then click the button again."
                exit 1
              fi
              # 它的安装后脚本默认会往本机所有 AI 工具（Claude Code、Codex、Cursor…）各装 25 个 skill；
              # CI=1 是它自己的开关：只下载校验过的二进制，不动别的工具配置
              echo "（只安装命令行工具，不往其他 AI 工具里装 skill）"
              CI=1 npm install -g @volcengine/ark-cli@latest || { echo; echo "安装失败。若提示权限错误（EACCES），用 brew install node 装的 Node 可避免。"; exit 1; }
              """#
            // 官方安装脚本默认还会 `bl skill init` 往各 AI 工具装 skill：用它自己的开关跳过；
            // PATH 里已有 ~/.local/bin，它也就不会去改 ~/.zshrc
            : #"""
              echo "（只安装命令行工具，不往其他 AI 工具里装 skill）"
              curl -fsSL https://bailian.aliyun.com/cli/install.sh | BAILIAN_SKIP_SKILL_INIT=1 bash || exit 1
              """#
    }
    var login: String { self == .ark ? "arkcli auth login volc-sso" : "bl auth login --console" }

    /// 火山：{items:[{product:"coding-plan", periods:[{label:"session"|"weekly"|"monthly", percent 0–100, reset_at RFC3339}]}]}
    /// 阿里：{instanceType, per5Hour|perWeek|perBillMonth:{usedQuota,totalQuota,percentage 0–1,resetTime 秒或毫秒}}；没订阅 = {}
    static func parse(_ cli: OfficialCLI, _ json: Any, capturedAt: TimeInterval) -> CLIQuota? {
        guard let j = json as? [String: Any] else { return nil }
        var q = CLIQuota()
        func win(_ pct: Double?, _ reset: TimeInterval?, _ secs: Double) -> QuotaWindow? {
            guard let p = Fmt.pct(pct) else { return nil }
            // 重置时间只认 2001–2100 年之间的有限值：离谱的时间戳下游转整数会崩
            let r = reset.flatMap { $0.isFinite && $0 > 1e9 && $0 < 4.2e9 ? $0 : nil }
            return QuotaWindow(usedPct: p, resetsAt: r, capturedAt: capturedAt, windowSeconds: secs)
        }
        switch cli {
        case .ark:
            // 先认错误，再认「没订阅」：带 error 的条目不能当成已登录无订阅
            guard j["error"] == nil, let all = j["items"] as? [[String: Any]] else { return nil }
            let items = all.filter { ($0["product"] as? String ?? "coding-plan") == "coding-plan" }
            if items.contains(where: { $0["error"] != nil }) { return nil }
            guard let item = items.first, item["subscribed"] as? Bool != false else { q.noSubscription = true; return q }
            q.plan = (item["tier"] as? String).map { "Coding Plan \($0.capitalized)" } ?? ""
            for p in item["periods"] as? [[String: Any]] ?? [] {
                let w = win((p["percent"] as? NSNumber)?.doubleValue, Fmt.parseISODate(p["reset_at"] as? String), 0)
                switch p["label"] as? String {
                case "session", "5h": q.fiveHour = w.map { var w = $0; w.windowSeconds = 5 * 3600; return w }
                case "weekly": q.weekly = w.map { var w = $0; w.windowSeconds = 7 * 86400; return w }
                case "monthly": q.monthly = w.map { var w = $0; w.windowSeconds = 30 * 86400; return w }
                default: break
                }
            }
        case .bailian:
            if j.isEmpty { q.noSubscription = true; return q }
            q.plan = j["instanceType"] as? String ?? ""
            func period(_ k: String, _ secs: Double) -> QuotaWindow? {
                guard let e = j[k] as? [String: Any] else { return nil }
                var ratio = (e["percentage"] as? NSNumber)?.doubleValue
                if ratio == nil, let u = (e["usedQuota"] as? NSNumber)?.doubleValue, let t = (e["totalQuota"] as? NSNumber)?.doubleValue, t > 0 { ratio = u / t }
                var reset = (e["resetTime"] as? NSNumber)?.doubleValue
                if let r = reset, r > 1e12 { reset = r / 1000 }            // 毫秒
                return win(ratio.map { max(-1, min(2, $0)) * 100 }, reset, secs)
            }
            q.fiveHour = period("per5Hour", 5 * 3600)
            q.weekly = period("perWeek", 7 * 86400)
            q.monthly = period("perBillMonth", 30 * 86400)
        }
        return ((q.fiveHour ?? q.weekly ?? q.monthly) != nil || q.noSubscription) ? q : nil
    }
}

public final class OfficialQuota {
    public static let shared = OfficialQuota()

    public enum CLIState: Equatable {
        case notInstalled
        case notConnected(String)        // 装了，但没登录 / 报错（附一行原因）
        case connected(CLIQuota, at: TimeInterval)

        public var isConnected: Bool { if case .connected = self { return true } else { return false } }
        public func text(_ now: TimeInterval) -> String {
            switch self {
            case .notInstalled: return L("未安装", "Not installed")
            case .notConnected(let why): return why
            case .connected(let q, let at):
                return (q.noSubscription ? L("已登录 · 没有 Coding Plan 订阅", "Signed in · no Coding Plan") : L("已连接", "Connected"))
                    + L(" · 更新于 \(Fmt.agoShort(Int(max(0, min(now - at, 1e9)))))", " · updated \(Fmt.agoShort(Int(max(0, min(now - at, 1e9)))))")
            }
        }
    }

    public struct RegisteredKey: Identifiable, Equatable {
        public init(account: String, host: String, fingerprint: String, name: String) {
            self.account = account; self.host = host; self.fingerprint = fingerprint; self.name = name
        }
        public var account: String       // "host#指纹"
        public var host: String
        public var fingerprint: String
        public var name: String
        public var id: String { account }
    }

    /// 可登记的厂商：只有这些有「拿推理 key 查自己用量」的公开接口
    public static let providers: [(name: String, host: String)] = [
        ("智谱 GLM", "open.bigmodel.cn"), ("Z.ai", "api.z.ai"), ("MiniMax", "api.minimaxi.com"),
        ("DeepSeek", "api.deepseek.com"), ("OpenRouter", "openrouter.ai"), ("Moonshot / Kimi API", "api.moonshot.cn"),
    ]
    static let service = "com.haifeng.vibegauge.usage-key"
    static let interval: TimeInterval = 300

    private let queue = DispatchQueue(label: "vibegauge.official-quota", qos: .utility)
    private let lock = NSLock()
    private var keyRows: [String: [String: Any]] = [:]
    private var cli: [OfficialCLI: CLIState] = [:]
    private var lastRun: TimeInterval = 0
    private var running = false
    private var rerun = false                          // 跑的中途又登记了 key：跑完马上再来一轮
    private var fastUntil: TimeInterval = 0          // 刚点过「连接」：这段时间内 20 秒查一次，登录完很快就能看到
    private var keyCache: [String: String] = [:]     // 本次运行读过的 key：钥匙串授权弹窗每次启动最多一次
    private var denied = Set<String>()                // 用户在钥匙串弹窗里拒绝了：本次运行不再问
    private var removedAt: [String: TimeInterval] = [:]  // 删掉的时刻：比它早开始的那轮查询结果不能再写回来

    // MARK: 扫描侧

    public func snapshot() -> (keys: [String: [String: Any]], cli: [OfficialCLI: CLIState]) {
        lock.lock(); defer { lock.unlock() }
        return (keyRows, cli)
    }

    public func state(_ c: OfficialCLI) -> CLIState {
        lock.lock(); defer { lock.unlock() }
        return cli[c] ?? (Self.binary(c.bin) == nil ? .notInstalled : .notConnected(L("还没读取", "Not read yet")))
    }

    /// 每次扫描都调：到点了才在后台跑一轮
    public func refreshIfDue(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let due = force || now - lastRun >= (now < fastUntil ? 20 : Self.interval)
        if running && force { rerun = true }
        guard due, !running else { lock.unlock(); return }
        running = true
        lastRun = now
        lock.unlock()
        queue.async { [self] in
            let started = Date().timeIntervalSince1970
            let keys = self.probeKeys()
            var states: [OfficialCLI: CLIState] = [:]
            for c in OfficialCLI.allCases { states[c] = self.readCLI(c) }
            lock.lock()
            keyRows = keys.filter { (removedAt[$0.key] ?? 0) < started }
            for (acc, t) in removedAt where t >= started { keyCache[acc] = nil }
            cli = states
            running = false
            if rerun { rerun = false; lastRun = 0 }
            lock.unlock()
        }
    }

    // MARK: A. 钥匙串登记的 key

    static func fingerprint(_ key: String) -> String {
        // 与代理的 key 指纹同算法（sha256(头部值) 前 8 位），同一个 key 经代理的调用会并到同一张卡
        SHA256.hash(data: Data(("Bearer " + key).utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// 客户端用 x-api-key 直接发 key 时，代理记的是原值的指纹
    static func rawFingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    public func register(host: String, key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 16, !key.contains(where: \.isWhitespace) else {
            throw NSError(domain: "VibeGauge", code: 10, userInfo: [NSLocalizedDescriptionKey: L("这不像一个 API key（太短或含空格）", "That doesn't look like an API key (too short or contains spaces)")])
        }
        let account = "\(host)#\(Self.fingerprint(key))"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "VibeGauge usage key (\(host))"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else {
            throw NSError(domain: "VibeGauge", code: Int(st), userInfo: [NSLocalizedDescriptionKey: L("写入钥匙串失败（\(st)）", "Couldn't save to Keychain (\(st))")])
        }
        lock.lock(); keyCache[account] = key; denied.remove(account); removedAt[account] = nil; lock.unlock()
        refreshIfDue(force: true)
    }

    @discardableResult
    public func remove(_ account: String) -> Bool {
        let st = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: account] as CFDictionary)
        lock.lock(); keyCache[account] = nil; keyRows[account] = nil; removedAt[account] = Date().timeIntervalSince1970; lock.unlock()
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// 只读属性（不读 key 本身，不会弹授权）
    public func registered() -> [RegisteredKey] {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { a -> RegisteredKey? in
            guard let acc = a[kSecAttrAccount as String] as? String else { return nil }
            let parts = acc.split(separator: "#", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let name = Self.providers.first { $0.host == parts[0] }?.name ?? parts[0]
            return RegisteredKey(account: acc, host: parts[0], fingerprint: parts[1], name: name)
        }.sorted { $0.account < $1.account }
    }

    private func readKey(_ account: String) -> String? {
        lock.lock()
        if let k = keyCache[account] { lock.unlock(); return k }
        if denied.contains(account) { lock.unlock(); return nil }
        lock.unlock()
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        lock.lock(); defer { lock.unlock() }
        guard st == errSecSuccess, let d = out as? Data, let k = String(data: d, encoding: .utf8) else {
            if st == errSecAuthFailed || st == errSecUserCanceled || st == errSecInteractionNotAllowed { denied.insert(account) }
            return nil
        }
        keyCache[account] = k
        return k
    }

    private func probeKeys() -> [String: [String: Any]] {
        let list = registered()
        guard !list.isEmpty, let script = Bundle.main.path(forResource: "vibegauge-proxy", ofType: "py") else { return [:] }
        var rows: [String: [String: Any]] = [:]
        for r in list {
            guard let key = readKey(r.account) else {
                rows[r.account] = ["provider": r.name, "error": L("钥匙串未授权读取", "Keychain access not allowed"), "captured_at": Date().timeIntervalSince1970]
                continue
            }
            let req = (try? JSONSerialization.data(withJSONObject: ["host": r.host, "key": key])) ?? Data()
            let res = Self.run("/usr/bin/python3", [script, "--probe"], stdin: req, timeout: 25)
            if var j = Self.firstJSONObject(res.out) as? [String: Any] {
                j["_registered"] = true
                j["_alt_fp"] = Self.rawFingerprint(key)
                rows[r.account] = j
            }
            else { rows[r.account] = ["provider": r.name, "error": res.timedOut ? L("查询超时", "Timed out") : L("查询失败", "Query failed"), "captured_at": Date().timeIntervalSince1970] }
        }
        return rows
    }

    // MARK: B. 官方 CLI

    static var searchDirs: [String] {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(h)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(h)/.npm-global/bin", "\(h)/.volta/bin", "\(h)/.bun/bin"]
        let nvm = "\(h)/.nvm/versions/node"
        // 只认 v1.2.3 这种版本目录名
        for v in ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed()
            where v.range(of: #"^v[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil { dirs.append("\(nvm)/\(v)/bin") }
        return dirs
    }

    static func binary(_ name: String) -> String? {
        searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func readCLI(_ c: OfficialCLI) -> CLIState {
        guard let bin = Self.binary(c.bin) else { return .notInstalled }
        let now = Date().timeIntervalSince1970
        let res = Self.run(bin, c.args, stdin: nil, timeout: 25)
        if res.timedOut { return .notConnected(L("读取超时", "Timed out")) }
        if res.status == 0, let j = Self.firstJSONObject(res.out), let q = OfficialCLI.parse(c, j, capturedAt: now) {
            return .connected(q, at: now)
        }
        // 没登录 / 令牌过期 / 其他报错：给一行原因，不贴整段输出。arkcli 把错误也写成 JSON：{ok:false, error:{message}} 或 items[].error
        let j = Self.firstJSONObject(res.out) as? [String: Any]
        let jsonErr = ((j?["error"] as? [String: Any])?["message"] as? String)
            ?? ((j?["items"] as? [[String: Any]])?.compactMap { $0["error"] as? String }.first)
        let msg = jsonErr ?? ((String(data: res.err, encoding: .utf8) ?? "") + (String(data: res.out, encoding: .utf8) ?? ""))
        let line = msg.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let lower = msg.lowercased()
        if ["login", "auth", "token", "credential", "登录", "unauthorized", "expired"].contains(where: lower.contains) {
            return .notConnected(L("需要登录", "Sign-in required"))
        }
        return .notConnected(line.isEmpty ? L("读取失败（退出码 \(res.status)）", "Failed (exit \(res.status))") : String(line.prefix(80)))
    }

    /// 单引号包住整段，里面的单引号拆成 '\'' ：目录名里的 $() / 反引号 / 引号都不会被 shell 解释
    static func shellQuote(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func connectScript(_ c: OfficialCLI, needsInstall: Bool) -> String {
        """
        #!/bin/bash
        # VibeGauge：连接\(c.title)的官方额度（由 VibeGauge 生成，可删除）
        export PATH=\(Self.shellQuote(Self.searchDirs.joined(separator: ":"))):"$PATH"
        finish() { echo; read -n 1 -s -r -p "按任意键关闭 / Press any key to close"; echo; exit "$1"; }
        echo "== VibeGauge：连接\(c.title)官方额度 =="
        echo
        \(needsInstall ? "if ! command -v \(c.bin) >/dev/null 2>&1; then\n  echo \"安装 \(c.bin) …\"\n  (\n\(c.install)\n  ) || finish 1\nfi" : "")
        command -v \(c.bin) >/dev/null 2>&1 || { echo "没找到 \(c.bin)，安装可能没有成功。"; finish 1; }
        echo "登录（会打开浏览器，按页面提示完成）…"
        \(c.login) || finish 1
        echo
        echo "完成。回到 VibeGauge，额度一分钟内出现。 / Done. The quota shows up in VibeGauge within a minute."
        finish 0
        """
    }

    /// 写一个 .command 让「终端」执行安装 / 登录：用户看得见每一步，不需要自动化权限
    public func openConnect(_ c: OfficialCLI) {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(h)/.config/vibegauge"
        let path = "\(dir)/connect-\(c.rawValue).command"
        let script = Self.connectScript(c, needsInstall: Self.binary(c.bin) == nil)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(atPath: path)
            guard FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            lock.lock(); fastUntil = Date().timeIntervalSince1970 + 600; lastRun = 0; lock.unlock()
        } catch {}
    }

    // MARK: 工具

    static func firstJSONObject(_ d: Data) -> Any? {
        if let j = try? JSONSerialization.jsonObject(with: d) { return j }
        // 前面混了提示行（更新提醒等）：从第一个 { 开始再试
        guard let i = d.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try? JSONSerialization.jsonObject(with: d[i...])
    }

    static func run(_ exe: String, _ args: [String], stdin: Data?, timeout: TimeInterval) -> (status: Int32, out: Data, err: Data, timedOut: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        // 输出随到随收（不阻塞读）；超时以「进程退出」为准 —— 管道 EOF 不等于进程结束，后代进程也可能一直占着管道
        final class Box { let lock = NSLock(); var out = Data(); var err = Data() }
        let box = Box()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }      // EOF：不摘掉会空转
            box.lock.lock(); box.out.append(d); box.lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }      // EOF：不摘掉会空转
            box.lock.lock(); box.err.append(d); box.lock.unlock()
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (-1, Data(), Data(), false)
        }
        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }   // 对方提前退出时抛错而不是崩（SIGPIPE 已忽略）
        try? inPipe.fileHandleForWriting.close()
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // ponytail: 退出后再给 0.2 秒收尾输出；后代进程若还占着管道，多出的输出不要了
        Thread.sleep(forTimeInterval: 0.2)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        box.lock.lock(); defer { box.lock.unlock() }
        return (p.isRunning ? -9 : p.terminationStatus, box.out, box.err, timedOut)
    }
}
