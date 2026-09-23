import Cocoa

// 往已退出的子进程管道里写会收到 SIGPIPE，默认直接杀掉整个 App：忽略它，让写入返回错误
signal(SIGPIPE, SIG_IGN)

// `VibeGauge --install-proxy` / `--uninstall-proxy`：命令行装卸 API 记账代理（与菜单同一条代码路径）
if CommandLine.arguments.contains("--install-proxy") {
    do {
        try ProxyManager.shared.install()
        print(L("已安装并启动：\(ProxyManager.shared.prefix)  日志 \(ProxyManager.shared.logPath)", "Installed and started: \(ProxyManager.shared.prefix)  log \(ProxyManager.shared.logPath)"))
    } catch {
        print(L("安装失败：\(error.localizedDescription)", "Installation failed: \(error.localizedDescription)"))
        exit(1)
    }
    exit(0)
}
if CommandLine.arguments.contains("--uninstall-proxy") {
    ProxyManager.shared.uninstall()
    print(L("已卸载", "Uninstalled"))
    exit(0)
}

// `VibeGauge --selftest`：离线确定性测试（CI 必跑）；`--diagnose`：本机诊断快照（脱敏，排障用）
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    print(L("离线自测全部通过", "All offline self-tests passed"))
    exit(0)
}
if CommandLine.arguments.contains("--diagnose") {
    exit(Diagnostics.run())
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
