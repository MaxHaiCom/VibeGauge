import Cocoa
import ServiceManagement
import UserNotifications

enum DisplayStyle: String, CaseIterable {
    case capsuleBattery = "胶囊能量条 (数字居中，参考图同款)"
    case chipFrame = "芯片框架 (数字居中)"
    case circleRing = "微型环形进度圈"
    case textOnly = "清晰纯数字 (如 58%)"
    case horizontalCompact = "小图标 + 适中数字"
    case iconOnly = "纯芯片图标"
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var autoCleanTimer: Timer?
    
    private var currentReport = ScanReport()
    
    // UserDefaults Keys
    private let autoCleanKey = "autoCleanEnabled"
    private let displayStyleKey = "menuBarDisplayStyle"
    
    var isAutoCleanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCleanKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCleanKey)
            setupAutoCleanTimer()
        }
    }
    
    var currentStyle: DisplayStyle {
        get {
            if let raw = UserDefaults.standard.string(forKey: displayStyleKey),
               let style = DisplayStyle(rawValue: raw) {
                return style
            }
            // 默认采用用户参考图同款：胶囊外框 + 居中数字
            return .capsuleBattery
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: displayStyleKey)
            renderStatusButton(report: currentReport)
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
    
    // MARK: - Multi-Style Rendering
    private func renderImage(for style: DisplayStyle, percentage: Int) -> NSImage {
        switch style {
        case .capsuleBattery:
            // 方案 1: 胶囊能量框 (参考图同款: 外框 + 内部进度 + 居中数字)
            let width: CGFloat = 26.0
            let height: CGFloat = 22.0
            let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                // 外框主体
                let bodyWidth: CGFloat = 20.0
                let bodyHeight: CGFloat = 12.5
                let bodyX: CGFloat = 1.5
                let bodyY: CGFloat = (height - bodyHeight) / 2.0
                
                let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.2, yRadius: 3.2)
                bodyPath.lineWidth = 1.2
                NSColor.black.setStroke()
                bodyPath.stroke()
                
                // 右侧微型电极帽
                let capWidth: CGFloat = 1.5
                let capHeight: CGFloat = 4.6
                let capX: CGFloat = bodyX + bodyWidth + 0.8
                let capY: CGFloat = bodyY + (bodyHeight - capHeight) / 2.0
                let capPath = NSBezierPath(roundedRect: NSRect(x: capX, y: capY, width: capWidth, height: capHeight), xRadius: 0.75, yRadius: 0.75)
                NSColor.black.withAlphaComponent(0.65).setFill()
                capPath.fill()
                
                // 内部进度条 (半透明填充)
                let pad: CGFloat = 1.6
                let maxW = bodyWidth - (pad * 2)
                let fillW = maxW * CGFloat(percentage) / 100.0
                if fillW > 1.0 {
                    let fillRect = NSRect(x: bodyX + pad, y: bodyY + pad, width: fillW, height: bodyHeight - (pad * 2))
                    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.8, yRadius: 1.8)
                    NSColor.black.withAlphaComponent(0.22).setFill()
                    fillPath.fill()
                }
                
                // 内部正中心数字
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

        case .chipFrame:
            // 方案 2: 芯片框架 (带顶部/底部芯片引脚，数字居中)
            let width: CGFloat = 25.0
            let height: CGFloat = 22.0
            let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                let bodyWidth: CGFloat = 19.0
                let bodyHeight: CGFloat = 13.0
                let bodyX: CGFloat = (width - bodyWidth) / 2.0
                let bodyY: CGFloat = (height - bodyHeight) / 2.0
                
                let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.8, yRadius: 2.8)
                bodyPath.lineWidth = 1.2
                NSColor.black.setStroke()
                bodyPath.stroke()
                
                // 芯片引脚 (上下各 3 个)
                let pinW: CGFloat = 1.5
                let pinH: CGFloat = 1.8
                let pinSpacing: CGFloat = 4.2
                let startX: CGFloat = bodyX + 3.2
                for i in 0..<3 {
                    let px = startX + CGFloat(i) * pinSpacing
                    NSBezierPath(roundedRect: NSRect(x: px, y: bodyY + bodyHeight, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
                    NSBezierPath(roundedRect: NSRect(x: px, y: bodyY - pinH, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
                }
                
                // 内部进度填充
                let pad: CGFloat = 1.6
                let maxW = bodyWidth - (pad * 2)
                let fillW = maxW * CGFloat(percentage) / 100.0
                if fillW > 1.0 {
                    let fillRect = NSRect(x: bodyX + pad, y: bodyY + pad, width: fillW, height: bodyHeight - (pad * 2))
                    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
                    NSColor.black.withAlphaComponent(0.22).setFill()
                    fillPath.fill()
                }
                
                // 居中数字
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

        case .textOnly:
            // 方案 3: 纯大号数字 (字号 11.5pt，横向仅 28pt)
            let width: CGFloat = 28.0
            let img = NSImage(size: NSSize(width: width, height: 22.0), flipped: false) { rect in
                let text = "\(percentage)%"
                let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraphStyle
                ]
                text.draw(in: NSRect(x: 0, y: 4.0, width: width, height: 14.0), withAttributes: attrs)
                return true
            }
            img.isTemplate = true
            return img
            
        case .circleRing:
            // 方案 4: Apple Watch 风格微型圆环 (宽度仅 18pt)
            let size: CGFloat = 18.0
            let img = NSImage(size: NSSize(width: size, height: 22.0), flipped: false) { rect in
                let center = NSPoint(x: size / 2.0, y: 11.0)
                let radius: CGFloat = 6.5
                let lineWidth: CGFloat = 2.0
                
                let bgPath = NSBezierPath()
                bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                bgPath.lineWidth = lineWidth
                NSColor.black.withAlphaComponent(0.25).setStroke()
                bgPath.stroke()
                
                let usedRatio = CGFloat(100 - percentage) / 100.0
                if usedRatio > 0 {
                    let startAngle: CGFloat = 90.0
                    let endAngle: CGFloat = 90.0 - (usedRatio * 360.0)
                    let activePath = NSBezierPath()
                    activePath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                    activePath.lineWidth = lineWidth
                    activePath.lineCapStyle = .round
                    NSColor.black.setStroke()
                    activePath.stroke()
                }
                return true
            }
            img.isTemplate = true
            return img
            
        case .horizontalCompact:
            // 方案 5: 小图标 + 适中数字 (横向 36pt)
            let width: CGFloat = 36.0
            let img = NSImage(size: NSSize(width: width, height: 22.0), flipped: false) { rect in
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10.0, weight: .medium)
                if let symbol = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                    let iconSize: CGFloat = 11.0
                    symbol.draw(in: NSRect(x: 0, y: 5.5, width: iconSize, height: iconSize))
                }
                let text = "\(percentage)%"
                let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .right
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraphStyle
                ]
                text.draw(in: NSRect(x: 12.0, y: 4.5, width: width - 12.0, height: 14.0), withAttributes: attrs)
                return true
            }
            img.isTemplate = true
            return img
            
        case .iconOnly:
            // 方案 6: 纯芯片图标
            let width: CGFloat = 20.0
            let img = NSImage(size: NSSize(width: width, height: 22.0), flipped: false) { rect in
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                if let symbol = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                    let iconSize: CGFloat = 14.0
                    let iconX = (width - iconSize) / 2.0
                    let iconY = (22.0 - iconSize) / 2.0
                    symbol.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
                }
                return true
            }
            img.isTemplate = true
            return img
        }
    }
    
    private func renderStatusButton(report: ScanReport) {
        guard let button = statusItem.button else { return }
        
        let img = renderImage(for: currentStyle, percentage: report.freePercentage)
        button.image = img
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
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
        
        // 3. 菜单栏显示样式切换
        let styleSubmenu = NSMenu()
        for style in DisplayStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(changeStyleAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = (style == currentStyle) ? .on : .off
            styleSubmenu.addItem(item)
        }
        let styleMenuItem = NSMenuItem(title: "菜单栏显示样式", action: nil, keyEquivalent: "")
        styleMenuItem.submenu = styleSubmenu
        menu.addItem(styleMenuItem)
        
        // 4. 选项偏好
        let autoCleanItem = NSMenuItem(title: "定时自动清理 (每 30 分钟)", action: #selector(toggleAutoClean), keyEquivalent: "")
        autoCleanItem.target = self
        autoCleanItem.state = isAutoCleanEnabled ? .on : .off
        menu.addItem(autoCleanItem)
        
        let launchItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. 控制操作
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
    
    @objc func changeStyleAction(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? DisplayStyle {
            currentStyle = style
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
