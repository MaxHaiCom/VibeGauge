import Cocoa
import SwiftUI
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
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
    
    // MARK: - 芯片框架图标 (内嵌居中数字)
    private func renderChipFrameImage(percentage: Int) -> NSImage {
        let width: CGFloat = 25.0
        let height: CGFloat = 22.0
        
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bodyWidth: CGFloat = 19.5
            let bodyHeight: CGFloat = 13.0
            let bodyX: CGFloat = (width - bodyWidth) / 2.0
            let bodyY: CGFloat = (height - bodyHeight) / 2.0
            
            // 1. 芯片主体轮廓
            let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.8, yRadius: 2.8)
            bodyPath.lineWidth = 1.2
            NSColor.black.setStroke()
            bodyPath.stroke()
            
            // 2. 芯片四周引脚 (上下各 3 个金属引脚)
            let pinW: CGFloat = 1.5
            let pinH: CGFloat = 1.8
            let pinSpacing: CGFloat = 4.3
            let startX: CGFloat = bodyX + 3.4
            for i in 0..<3 {
                let px = startX + CGFloat(i) * pinSpacing
                NSBezierPath(roundedRect: NSRect(x: px, y: bodyY + bodyHeight, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: px, y: bodyY - pinH, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
            }
            
            // 3. 内部进度轻量填充
            let pad: CGFloat = 1.6
            let maxW = bodyWidth - (pad * 2)
            let fillW = maxW * CGFloat(percentage) / 100.0
            if fillW > 1.0 {
                let fillRect = NSRect(x: bodyX + pad, y: bodyY + pad, width: fillW, height: bodyHeight - (pad * 2))
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
                NSColor.black.withAlphaComponent(0.22).setFill()
                fillPath.fill()
            }
            
            // 4. 居中数字
            let text = "\(percentage)"
            let fontSize: CGFloat = (percentage >= 100) ? 7.2 : 8.5
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: pStyle
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textY = bodyY + (bodyHeight - textSize.height) / 2.0
            let textRect = NSRect(x: bodyX, y: textY, width: bodyWidth, height: textSize.height)
            text.draw(in: textRect, withAttributes: attrs)
            return true
        }
        
        img.isTemplate = true
        return img
    }
    
    private func renderStatusButton(report: ScanReport) {
        guard let button = statusItem.button else { return }
        button.image = renderChipFrameImage(percentage: report.freePercentage)
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
    }
    
    // MARK: - NSMenuDelegate (嵌入 SwiftUI 图表卡片)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let report = currentReport
        
        // 1. SwiftUI 图表面板项 (彻底解决灰色纯文本割裂感)
        let dashboard = DashboardView(
            report: report,
            onCleanOrphans: { [weak self] in
                self?.menu.cancelTracking()
                self?.cleanOrphansAction()
            },
            onCleanNPX: { [weak self] in
                self?.menu.cancelTracking()
                self?.cleanNPXAction()
            }
        )
        
        let hosting = NSHostingView(rootView: dashboard)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        
        let cardItem = NSMenuItem()
        cardItem.view = hosting
        menu.addItem(cardItem)
        
        // 2. 可选：若有孤儿进程，提供展开明细选项
        if !report.orphanedGroups.isEmpty {
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
            
            let detailMenuItem = NSMenuItem(title: "查看断链服务明细...", action: nil, keyEquivalent: "")
            detailMenuItem.submenu = detailSubmenu
            menu.addItem(detailMenuItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. 偏好选项
        let autoCleanItem = NSMenuItem(title: "定时自动清理 (每 30 分钟)", action: #selector(toggleAutoClean), keyEquivalent: "")
        autoCleanItem.target = self
        autoCleanItem.state = isAutoCleanEnabled ? .on : .off
        menu.addItem(autoCleanItem)
        
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
    
    @objc func cleanNPXAction() {
        let freedMB = ProcessScanner.shared.cleanNPXCache()
        sendNotification(
            title: "NPX 缓存已清理",
            body: "已清空 ~/.npm/_npx 目录，释放约 \(String(format: "%.1f", freedMB)) MB 磁盘空间。"
        )
        updateStatus()
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
