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
    private let showPercentageKey = "showPercentageInMenuBar"
    
    var isAutoCleanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCleanKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCleanKey)
            setupAutoCleanTimer()
        }
    }
    
    var isShowPercentageEnabled: Bool {
        get {
            // Default to true
            UserDefaults.standard.object(forKey: showPercentageKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: showPercentageKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showPercentageKey)
            renderStatusButton(report: currentReport)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Setup SF Symbol icon
        if let button = statusItem.button {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let img = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "VibeClean")?.withSymbolConfiguration(symbolConfig) {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            }
        }
        
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        updateStatus()
        
        timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        
        setupAutoCleanTimer()
    }
    
    private func setupAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil
        
        if isAutoCleanEnabled {
            autoCleanTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
                self?.performSilentAutoClean()
            }
        }
    }
    
    private func performSilentAutoClean() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ProcessScanner.shared.scan()
            if !report.allOrphanPids.isEmpty {
                let result = ProcessScanner.shared.killProcesses(pids: report.allOrphanPids)
                DispatchQueue.main.async {
                    self?.sendNotification(
                        title: "VibeClean 内存优化",
                        body: "已静默清理 \(result.killedCount) 个残留 AI 进程，回收 \(String(format: "%.1f", result.freedMB)) MB 内存。"
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
        
        if isShowPercentageEnabled {
            let freePct = report.freePercentage
            let text = " \(freePct)%"
            let attrTitle = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            button.attributedTitle = attrTitle
        } else {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        }
    }
    
    // MARK: - NSMenuDelegate
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let report = currentReport
        
        // 1. 内存压力与健康状态
        let healthLabel: String
        if report.freePercentage >= 60 {
            healthLabel = "正常"
        } else if report.freePercentage >= 40 {
            healthLabel = "偏高"
        } else {
            healthLabel = "严重 (有卡顿风险)"
        }
        
        let pressureItem = NSMenuItem(
            title: "内存压力：\(healthLabel) (可用 \(report.freePercentage)%)",
            action: nil,
            keyEquivalent: ""
        )
        pressureItem.isEnabled = false
        menu.addItem(pressureItem)
        
        let memDetailItem = NSMenuItem(
            title: "物理内存：已用 \(String(format: "%.1f", report.usedMemoryGB)) GB / \(String(format: "%.1f", report.totalMemoryGB)) GB",
            action: nil,
            keyEquivalent: ""
        )
        memDetailItem.isEnabled = false
        menu.addItem(memDetailItem)
        
        let compStr = report.compressorGB > 1.0
            ? String(format: "%.2f GB", report.compressorGB)
            : "\(Int(report.compressorGB * 1024)) MB"
        let swapStr = report.swapUsedGB > 1.0
            ? String(format: "%.2f GB", report.swapUsedGB)
            : "\(Int(report.swapUsedGB * 1024)) MB"
        
        let vmItem = NSMenuItem(
            title: "虚拟内存：压缩池 \(compStr) · Swap \(swapStr)",
            action: nil,
            keyEquivalent: ""
        )
        vmItem.isEnabled = false
        menu.addItem(vmItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. 核心操作：清理已断链的 AI 工具与孤儿进程
        if !report.orphanedGroups.isEmpty {
            let memFormatted = report.totalOrphanMemMB > 1024
                ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                : "\(Int(report.totalOrphanMemMB)) MB"
            
            let cleanActionItem = NSMenuItem(
                title: "清理已退出的 AI 残留进程 (\(memFormatted))",
                action: #selector(cleanOrphansAction),
                keyEquivalent: "c"
            )
            cleanActionItem.target = self
            menu.addItem(cleanActionItem)
            
            let summaryText = "已检测到 \(report.orphanedGroups.count) 项断链服务 (共 \(report.totalOrphanCount) 个后台进程)"
            let summaryItem = NSMenuItem(title: summaryText, action: nil, keyEquivalent: "")
            summaryItem.isEnabled = false
            menu.addItem(summaryItem)
            
            // 明细子菜单 (清晰可读的名字，无哈希无乱码)
            let detailSubmenu = NSMenu()
            for group in report.orphanedGroups {
                let groupMem = group.totalMemMB > 1024
                    ? String(format: "%.1f GB", group.totalMemMB / 1024.0)
                    : "\(Int(group.totalMemMB)) MB"
                let subTitle = "\(group.serviceName) (\(groupMem) · \(group.processCount) 个进程)"
                let subItem = NSMenuItem(title: subTitle, action: nil, keyEquivalent: "")
                subItem.isEnabled = false
                detailSubmenu.addItem(subItem)
            }
            
            let detailMenuItem = NSMenuItem(title: "   查看服务明细...", action: nil, keyEquivalent: "")
            detailMenuItem.submenu = detailSubmenu
            menu.addItem(detailMenuItem)
        } else {
            let cleanItem = NSMenuItem(title: "运行环境干净，暂无残留后台服务", action: nil, keyEquivalent: "")
            cleanItem.isEnabled = false
            menu.addItem(cleanItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. 选项偏好
        let autoCleanItem = NSMenuItem(title: "定时自动清理 (每 30 分钟)", action: #selector(toggleAutoClean), keyEquivalent: "")
        autoCleanItem.target = self
        autoCleanItem.state = isAutoCleanEnabled ? .on : .off
        menu.addItem(autoCleanItem)
        
        let showPctItem = NSMenuItem(title: "在菜单栏显示可用百分比", action: #selector(toggleShowPercentage), keyEquivalent: "")
        showPctItem.target = self
        showPctItem.state = isShowPercentageEnabled ? .on : .off
        menu.addItem(showPctItem)
        
        let launchItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. 控制操作
        let refreshItem = NSMenuItem(title: "重新扫描", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let quitItem = NSMenuItem(title: "退出 VibeClean", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    @objc func cleanOrphansAction() {
        let pids = currentReport.allOrphanPids
        guard !pids.isEmpty else { return }
        
        let result = ProcessScanner.shared.killProcesses(pids: pids)
        sendNotification(
            title: "清理完成",
            body: "已释放 \(result.killedCount) 个残留 AI 进程，回收 \(String(format: "%.1f", result.freedMB)) MB 内存。"
        )
        updateStatus()
    }
    
    @objc func toggleAutoClean() {
        isAutoCleanEnabled.toggle()
        updateStatus()
    }
    
    @objc func toggleShowPercentage() {
        isShowPercentageEnabled.toggle()
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
                print("Toggle launch error: \(error)")
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
