import AppKit
import ServiceManagement
import TrafficLightCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = StateEngine()
    private var widget: WidgetController!
    private var server: SocketServer!
    private var statusItem: NSStatusItem!
    private var sweepTimer: Timer?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onDisplayStateChanged = { [weak self] state in
            self?.widget.applyState(state)
            self?.updateStatusIcon(state)
        }

        widget = WidgetController(engine: engine)
        widget.show()

        setupStatusBar()
        startSweepTimer()
        startServer()

        widget.applyState(engine.displayState)
        updateStatusIcon(engine.displayState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: - IPC 服务

    private func startServer() {
        server = SocketServer { [weak self] request in
            guard let self else {
                return TLResponse.failure("App 正在退出", error: "shutting-down")
            }
            return self.engine.handle(request)
        }
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "TrafficLight 无法启动本地控制服务"
            alert.informativeText = "\(error.localizedDescription)\n\nCLI 将无法控制红绿灯。"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    // MARK: - 超时清扫

    private func startSweepTimer() {
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self.engine.sweep()
            self.widget.refreshTooltip()
        }
    }

    // MARK: - 状态栏

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusDot(.red)
        statusItem.button?.toolTip = "TrafficLight"

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func updateStatusIcon(_ state: StateEngine.DisplayState) {
        statusItem.button?.image = statusDot(state)
        statusItem.button?.toolTip = "TrafficLight · \(engine.statusLine)"
    }

    private func statusDot(_ state: StateEngine.DisplayState) -> NSImage {
        let color: NSColor
        switch state {
        case .red: color = NSColor.systemRed
        case .orange: color = NSColor.systemOrange
        case .green: color = NSColor.systemGreen
        }
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 11, height: 11))
        color.setFill()
        dot.fill()
        NSColor(calibratedWhite: 0, alpha: 0.25).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        img.unlockFocus()
        return img
    }

    // MARK: - 菜单动作

    @objc private func ackAction() {
        engine.handle(TLRequest(cmd: "ack", id: engine.pendingCompletion?.id))
    }

    @objc private func resetAction() {
        engine.handle(TLRequest(cmd: "reset"))
    }

    @objc private func toggleWidgetAction() {
        widget.setIsHidden(!widget.isHidden)
    }

    @objc private func sizeAction(_ sender: NSMenuItem) {
        widget.setScalePreset(sender.tag)
    }

    @objc private func resetPositionAction() {
        widget.resetPosition()
    }

    @objc private func loginItemAction(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        sender.state = sender.state == .on ? .off : .on
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = sender.state == .on ? .off : .on
        }
    }

    @objc private func aboutAction() {
        let alert = NSAlert()
        alert.icon = WidgetAssets.image(for: .green)
        alert.messageText = "TrafficLight 1.0.0"
        alert.informativeText = """
        桌面红绿灯 — Agent 状态指示器

        红色：空闲等待新任务
        橙色：任务执行中
        绿色：任务完成，待确认（点击绿灯确认）

        拖动移动 · 滚轮/捏合缩放 · 双击恢复大小

        CLI：trafficlight status
        https://github.com/Kz-Aven/TrafficLightController
        """
        alert.runModal()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

// MARK: - 菜单每次打开时重建（任务列表/状态实时变化）

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = engine.displayState

        let statusItem = NSMenuItem(title: "●  \(engine.statusLine)",
                                    action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        for task in engine.tasks.prefix(8) {
            let item = NSMenuItem(title: "    · \(task.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if engine.tasks.count > 8 {
            let more = NSMenuItem(title: "    … 共 \(engine.tasks.count) 个任务",
                                  action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }

        menu.addItem(.separator())

        if state == .green {
            let ack = NSMenuItem(title: "确认完成，回到红灯", action: #selector(ackAction),
                                 keyEquivalent: "")
            ack.target = self
            menu.addItem(ack)
        }
        let reset = NSMenuItem(title: "重置", action: #selector(resetAction), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: widget.isHidden ? "显示红绿灯" : "隐藏红绿灯",
                                action: #selector(toggleWidgetAction), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let sizeMenu = NSMenu()
        for (tag, title) in [(0, "小"), (1, "中"), (2, "大"), (3, "超大"), (4, "巨大")] {
            let item = NSMenuItem(title: title, action: #selector(sizeAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = widget.scalePreset == tag ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeParent = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        let pos = NSMenuItem(title: "恢复默认位置", action: #selector(resetPositionAction),
                             keyEquivalent: "")
        pos.target = self
        menu.addItem(pos)

        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "登录时启动", action: #selector(loginItemAction(_:)),
                                   keyEquivalent: "")
            login.target = self
            login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(login)
        }

        let about = NSMenuItem(title: "关于 TrafficLight", action: #selector(aboutAction),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 TrafficLight", action: #selector(quitAction),
                               keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}
