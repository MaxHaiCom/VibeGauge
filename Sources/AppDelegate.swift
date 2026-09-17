import Cocoa
import ServiceManagement
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var autoCleanTimer: Timer?
    
    private var currentReport = ScanReport()
    
    // UserDefaults Keys
    private let autoCleanKey = "autoCleanEnabled"
    
    var isAutoCleanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCleanKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCleanKey)
            setupAutoCleanTimer()
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification authorization
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Setup Status Item in Menu Bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        // Initial scan and update
        updateStatus()
        
        // Schedule regular update (every 10s)
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        
        // Setup auto-clean timer if enabled
        setupAutoCleanTimer()
    }
    
    private func setupAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil
        
        if isAutoCleanEnabled {
            // Run every 30 minutes
            autoCleanTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
                self?.performSilentAutoClean()
            }
        }
    }
    
    private func performSilentAutoClean() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ProcessScanner.shared.scan()
            if !report.orphanedMCPs.isEmpty {
                let pids = report.orphanedMCPs.map { $0.pid }
                let result = ProcessScanner.shared.killProcesses(pids: pids)
                
                DispatchQueue.main.async {
                    self?.sendNotification(
                        title: "VibeClean 静默清理",
                        body: "已自动清理 \(result.killedCount) 个孤儿 MCP 进程，释放 \(String(format: "%.1f", result.freedMB)) MB 内存。"
                    )
                    self?.updateStatus()
                }
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    @objc func updateStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = ProcessScanner.shared.scan()
            DispatchQueue.main.async {
                self?.currentReport = report
                self?.renderStatusButton(report: report)
            }
        }
    }
    
    private func renderStatusButton(report: ScanReport) {
        guard let button = statusItem.button else { return }
        
        let freePct = report.freePercentage
        let dotColor: NSColor
        let statusEmoji: String
        
        if freePct >= 60 {
            dotColor = NSColor.systemGreen
            statusEmoji = "●"
        } else if freePct >= 40 {
            dotColor = NSColor.systemOrange
            statusEmoji = "●"
        } else {
            dotColor = NSColor.systemRed
            statusEmoji = "●"
        }
        
        let orphanCount = report.orphanedMCPs.count
        var titleText = "\(statusEmoji) \(freePct)%"
        if orphanCount > 0 {
            let memStr = report.totalOrphanMemMB > 1024
                ? String(format: "%.1fG", report.totalOrphanMemMB / 1024.0)
                : "\(Int(report.totalOrphanMemMB))M"
            titleText += " (\(orphanCount)可清 \(memStr))"
        }
        
        let attrTitle = NSMutableAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        
        // Color the dot
        if let range = titleText.range(of: statusEmoji) {
            let nsRange = NSRange(range, in: titleText)
            attrTitle.addAttribute(.foregroundColor, value: dotColor, range: nsRange)
        }
        
        button.attributedTitle = attrTitle
    }
    
    // MARK: - NSMenuDelegate (Dynamic Build)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let report = currentReport
        
        // 1. 系统概览 Header
        let healthLabel: String
        if report.freePercentage >= 60 {
            healthLabel = "良好"
        } else if report.freePercentage >= 40 {
            healthLabel = "吃紧"
        } else {
            healthLabel = "严重卡顿风险"
        }
        
        let headerItem = NSMenuItem(title: "📊 内存可用健康度: \(report.freePercentage)% (\(healthLabel))", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
        let usedGB = report.totalMemoryGB * (1.0 - Double(report.freePercentage) / 100.0)
        let memDetailItem = NSMenuItem(
            title: "💾 物理内存: 已用 \(String(format: "%.1f", usedGB)) GB / \(String(format: "%.1f", report.totalMemoryGB)) GB",
            action: nil,
            keyEquivalent: ""
        )
        memDetailItem.isEnabled = false
        menu.addItem(memDetailItem)
        
        let swapStr = report.swapUsedMB > 1024
            ? String(format: "%.2f GB", report.swapUsedMB / 1024.0)
            : "\(Int(report.swapUsedMB)) MB"
        let compStr = report.compressorMB > 1024
            ? String(format: "%.2f GB", report.compressorMB / 1024.0)
            : "\(Int(report.compressorMB)) MB"
        
        let vmItem = NSMenuItem(title: "🔄 压缩内存池: \(compStr) | Swap: \(swapStr)", action: nil, keyEquivalent: "")
        vmItem.isEnabled = false
        menu.addItem(vmItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Vibe 垃圾进程专区 (孤儿 MCP)
        if !report.orphanedMCPs.isEmpty {
            let orphanMem = report.totalOrphanMemMB > 1024
                ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                : "\(Int(report.totalOrphanMemMB)) MB"
            
            let orphanTitleItem = NSMenuItem(title: "🧹 发现 \(report.orphanedMCPs.count) 个孤儿 MCP 进程 (约 \(orphanMem))", action: nil, keyEquivalent: "")
            orphanTitleItem.isEnabled = false
            menu.addItem(orphanTitleItem)
            
            let cleanActionItem = NSMenuItem(title: "▶️ 立即一键清理 (释放 \(orphanMem))", action: #selector(cleanOrphansAction), keyEquivalent: "c")
            cleanActionItem.target = self
            menu.addItem(cleanActionItem)
            
            // Submenu for orphan details
            let detailSubmenu = NSMenu()
            for o in report.orphanedMCPs {
                let subItem = NSMenuItem(title: "PID \(o.pid) | \(String(format: "%.1f", o.memMB))MB | \(o.name)", action: nil, keyEquivalent: "")
                subItem.isEnabled = false
                detailSubmenu.addItem(subItem)
            }
            let detailItem = NSMenuItem(title: "   查看孤儿列表...", action: nil, keyEquivalent: "")
            detailItem.submenu = detailSubmenu
            menu.addItem(detailItem)
        } else {
            let cleanItem = NSMenuItem(title: "✨ 无孤儿 MCP 进程 (系统干净)", action: nil, keyEquivalent: "")
            cleanItem.isEnabled = false
            menu.addItem(cleanItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. 本地开发端口服务
        if !report.devServers.isEmpty {
            let devTitle = NSMenuItem(title: "🌐 活跃本地开发服务 (\(report.devServers.count) 个)", action: nil, keyEquivalent: "")
            devTitle.isEnabled = false
            menu.addItem(devTitle)
            
            for dev in report.devServers {
                let devSubmenu = NSMenu()
                let stopItem = NSMenuItem(title: "停止此服务 (Kill PID \(dev.pid))", action: #selector(killSpecificProcess(_:)), keyEquivalent: "")
                stopItem.target = self
                stopItem.tag = dev.pid
                devSubmenu.addItem(stopItem)
                
                let devItem = NSMenuItem(
                    title: "  :\(dev.port) · \(dev.name) (PID \(dev.pid), \(String(format: "%.1f", dev.memMB))MB)",
                    action: nil,
                    keyEquivalent: ""
                )
                devItem.submenu = devSubmenu
                menu.addItem(devItem)
            }
        } else {
            let devNone = NSMenuItem(title: "🌐 暂无活跃本地开发端口", action: nil, keyEquivalent: "")
            devNone.isEnabled = false
            menu.addItem(devNone)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. 选项与控制
        let autoCleanItem = NSMenuItem(title: "⏱️ 每 30 分钟静默清理孤儿 MCP", action: #selector(toggleAutoClean), keyEquivalent: "")
        autoCleanItem.target = self
        autoCleanItem.state = isAutoCleanEnabled ? .on : .off
        menu.addItem(autoCleanItem)
        
        let launchItem = NSMenuItem(title: "🚀 登录时自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "🔄 立即重新扫描", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let quitItem = NSMenuItem(title: "🚪 退出 VibeClean", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    @objc func cleanOrphansAction() {
        let pids = currentReport.orphanedMCPs.map { $0.pid }
        guard !pids.isEmpty else { return }
        
        let result = ProcessScanner.shared.killProcesses(pids: pids)
        sendNotification(
            title: "VibeClean 清理完成",
            body: "已成功释放 \(result.killedCount) 个孤儿 MCP 进程，回收 \(String(format: "%.1f", result.freedMB)) MB 物理内存。"
        )
        updateStatus()
    }
    
    @objc func killSpecificProcess(_ sender: NSMenuItem) {
        let pid = sender.tag
        if pid > 0 {
            _ = ProcessScanner.shared.killProcesses(pids: [pid])
            updateStatus()
        }
    }
    
    @objc func toggleAutoClean() {
        isAutoCleanEnabled.toggle()
        updateStatus()
    }
    
    @objc func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if isLaunchAtLoginEnabled() {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                print("Toggle launch at login error: \(error)")
            }
        }
        updateStatus()
    }
    
    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    
    @objc func refreshAction() {
        updateStatus()
    }
    
    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
