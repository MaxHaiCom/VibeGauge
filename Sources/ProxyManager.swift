import Foundation

/// API 记账代理的安装 / 状态。代理本体是 Resources/vibegauge-proxy.py（纯 stdlib Python），
/// 安装时拷到 ~/.config/vibegauge/ 并注册 LaunchAgent（登录自启、崩溃自拉），不依赖 VibeGauge 存活。
final class ProxyManager {
    static let shared = ProxyManager()

    /// 配置的端口：默认 18790，被别的程序占了可改 `defaults write com.haifeng.vibegauge proxyPort 18791`，
    /// 再在菜单里重装代理 —— 只在安装时写进 LaunchAgent 的 VIBEGAUGE_PROXY_PORT。
    var configuredPort: Int { Self.validPort(UserDefaults.standard.integer(forKey: "proxyPort")) }
    /// 实际在用的端口：已安装就以 LaunchAgent 里写的为准（改了配置但没重装时，代理还在旧端口上跑），
    /// 探活、界面前缀、覆盖体检都读这个。
    var port: Int {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = (plist["EnvironmentVariables"] as? [String: Any])?["VIBEGAUGE_PROXY_PORT"] as? String,
              let installed = Int(raw) else { return configuredPort }
        return Self.validPort(installed)
    }
    static func validPort(_ v: Int) -> Int { (1024...65535).contains(v) ? v : 18790 }
    let label = "com.haifeng.vibegauge.proxy"
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var dir: String { "\(home)/.config/vibegauge" }
    var scriptPath: String { "\(dir)/vibegauge-proxy.py" }
    var callsPath: String { "\(dir)/api-calls.jsonl" }
    var quotaPath: String { "\(dir)/api-quota.json" }
    var logPath: String { "\(dir)/proxy.log" }
    var plistPath: String { "\(home)/Library/LaunchAgents/\(label).plist" }
    var prefix: String { "http://127.0.0.1:\(port)/" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    struct Health {
        var calls: Int
        var parsed: Int
        var errors: Int
        var uptime: Int
        var hosts: [String]
    }

    /// 同步探活，超时 0.4s；nil = 没在跑
    func health() -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/_vibegauge/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.4
        var result: Health? = nil
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true {
                result = Health(calls: j["calls"] as? Int ?? 0, parsed: j["parsed"] as? Int ?? 0, errors: j["errors"] as? Int ?? 0,
                                uptime: j["uptime_s"] as? Int ?? 0, hosts: j["hosts"] as? [String] ?? [])
            }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 0.5)
        return result
    }

    private var bundledScript: String? { Bundle.main.path(forResource: "vibegauge-proxy", ofType: "py") }

    /// 把 App 包里的脚本拷到 ~/.config/vibegauge/（内容不同才覆盖），返回是否有更新
    @discardableResult
    private func syncScript() throws -> Bool {
        guard let src = bundledScript else {
            throw NSError(domain: "VibeGauge", code: 1, userInfo: [NSLocalizedDescriptionKey: L("App 包里没有 vibegauge-proxy.py（build.sh 没拷？）", "vibegauge-proxy.py is missing from the app bundle (was it omitted by build.sh?)")])
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        // launchd 会先打开日志再启动 Python，预先建好才能从第一行起就是私有文件。
        if !FileManager.default.fileExists(atPath: logPath) {
            guard FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
        let new = try Data(contentsOf: URL(fileURLWithPath: src))
        if let old = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)), old == new {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
            return false
        }
        try new.write(to: URL(fileURLWithPath: scriptPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        return true
    }

    func install() throws {
        // 没装 Xcode 命令行工具时 /usr/bin/python3 只是个占位程序，LaunchAgent 会一直起不来还反复重试
        guard Self.pythonWorks() else {
            throw NSError(domain: "VibeGauge", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("python3 不可用：请先在终端运行 xcode-select --install 安装命令行工具", "python3 is unavailable: run `xcode-select --install` in Terminal first")])
        }
        try syncScript()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>/usr/bin/python3</string><string>\(scriptPath)</string></array>
            <key>EnvironmentVariables</key>
            <dict><key>VIBEGAUGE_PROXY_PORT</key><string>\(configuredPort)</string><key>PYTHONUNBUFFERED</key><string>1</string></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])          // 已有就先卸，忽略失败
        let rc = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if rc != 0 {
            throw NSError(domain: "VibeGauge", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: L("launchctl bootstrap 失败 rc=\(rc)，看 \(logPath)", "launchctl bootstrap failed (rc=\(rc)); see \(logPath)")])
        }
        // launchctl 成功只说明任务注册了：等它真的在端口上应答才算装好（端口被占、脚本报错都会在这里暴露）。
        // 应答的必须是刚起来的这个实例：运行了很久的是早就占着端口的另一个代理进程，本次安装其实没起来
        var stale = false
        for _ in 0..<15 {
            if let h = health() {
                if h.uptime < 30 { return }
                stale = true
            }
            usleep(200_000)
        }
        if stale {
            throw NSError(domain: "VibeGauge", code: 4, userInfo: [NSLocalizedDescriptionKey:
                L("端口 \(port) 已被另一个代理进程占用（不是刚安装的这个），先结束它再装", "Port \(port) is held by another proxy process (not the one just installed); stop it and retry")])
        }
        throw NSError(domain: "VibeGauge", code: 3, userInfo: [NSLocalizedDescriptionKey:
            L("代理已注册但没有在 127.0.0.1:\(port) 应答（端口被占用或启动报错），看 \(logPath)",
              "Proxy registered but not answering on 127.0.0.1:\(port) (port in use or startup error); see \(logPath)")])
    }

    static func pythonWorks() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// App 启动时：已安装且包里脚本更新了 → 覆盖并重启代理
    func syncIfInstalled() {
        guard isInstalled else { return }
        if (try? syncScript()) == true {
            _ = launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        }
    }

    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

/// 状态栏桥接：Claude Code / agy 刷新状态栏时会把官方额度交给状态栏命令，
/// 桥接脚本（Resources/vibegauge-statusline.py）截下一份写到 ~/.config/vibegauge/，再原样转交用户原来的状态栏。
/// 只在用户点「连接」时改对方的 settings.json（脚本先备份），「断开」还原。
final class StatuslineBridge {
    static let shared = StatuslineBridge()
    enum Tool: String, CaseIterable { case claude, agy }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var dir: String { "\(home)/.config/vibegauge" }
    private var scriptPath: String { "\(dir)/vibegauge-statusline.py" }
    /// 连接 / 断开一次只做一个：两个开关连点时，两个脚本进程不会同时改配置
    private let lock = NSLock()

    func settingsPath(_ tool: Tool) -> String {
        tool == .claude ? "\(home)/.claude/settings.json" : "\(home)/.gemini/antigravity-cli/settings.json"
    }

    /// 装了这个 CLI 才提供连接（看它的配置目录在不在）
    func toolInstalled(_ tool: Tool) -> Bool {
        FileManager.default.fileExists(atPath: tool == .claude ? "\(home)/.claude" : "\(home)/.gemini/antigravity-cli")
    }

    /// 对方配置里的状态栏命令就是本脚本 = 已连接
    func isConnected(_ tool: Tool) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath(tool)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sl = json["statusLine"] as? [String: Any], let cmd = sl["command"] as? String else { return false }
        return cmd.contains("vibegauge-statusline.py")
    }

    func connect(_ tool: Tool) throws {
        lock.lock(); defer { lock.unlock() }
        guard ProxyManager.pythonWorks() else {
            throw NSError(domain: "VibeGauge", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("python3 不可用：请先在终端运行 xcode-select --install 安装命令行工具", "python3 is unavailable: run `xcode-select --install` in Terminal first")])
        }
        try syncScript()
        try runScript(["--install", tool.rawValue])
    }

    func disconnect(_ tool: Tool) throws {
        lock.lock(); defer { lock.unlock() }
        try runScript(["--uninstall", tool.rawValue])
    }

    /// 待处理会话 Hook 已写进 Claude Code 配置（hooks 里有本脚本的 --hook 命令）
    func hooksConnected() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath(.claude)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String).map { $0.contains("vibegauge-statusline.py") && $0.contains("--hook") } ?? false }
            }
        }
    }

    func connectHooks() throws {
        lock.lock(); defer { lock.unlock() }
        guard ProxyManager.pythonWorks() else {
            throw NSError(domain: "VibeGauge", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("python3 不可用：请先在终端运行 xcode-select --install 安装命令行工具", "python3 is unavailable: run `xcode-select --install` in Terminal first")])
        }
        try syncScript()
        try runScript(["--install-hooks", "claude"])
    }

    func disconnectHooks() throws {
        lock.lock(); defer { lock.unlock() }
        try runScript(["--uninstall-hooks", "claude"])
    }

    /// App 启动时：连着的话把包里新版脚本同步过去（内容相同不写）
    func syncIfConnected() {
        guard Tool.allCases.contains(where: isConnected) || hooksConnected() else { return }
        try? syncScript()
    }

    private func syncScript() throws {
        guard let src = Bundle.main.path(forResource: "vibegauge-statusline", ofType: "py") else {
            throw NSError(domain: "VibeGauge", code: 1, userInfo: [NSLocalizedDescriptionKey: L("App 包里没有 vibegauge-statusline.py", "vibegauge-statusline.py is missing from the app bundle")])
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 已有目录也收紧：状态文件里的原命令会被执行，目录必须只有自己能写
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let new = try Data(contentsOf: URL(fileURLWithPath: src))
        if FileManager.default.contents(atPath: scriptPath) != new {
            try new.write(to: URL(fileURLWithPath: scriptPath), options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
    }

    private func runScript(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [scriptPath] + args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "VibeGauge", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                msg.isEmpty ? L("python3 不可用（需要 Xcode 命令行工具）", "python3 unavailable (Xcode Command Line Tools required)") : msg])
        }
    }
}
