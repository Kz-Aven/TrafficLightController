import AppKit
import TrafficLightCore

/// 悬浮红绿灯窗口（桌面宠物式交互）：
/// - 拖动窗口任意位置移动（isMovableByWindowBackground）
/// - 滚轮 / 捏合缩放，双击恢复默认大小
/// - 绿灯时单击 = 确认完成事件（ack）
/// - 悬浮在所有 App 之上，跨空间可见
final class WidgetController: NSObject, NSWindowDelegate {

    static let defaultScale: CGFloat = 1.0
    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 2.5

    private let panel: TrafficPanel
    private let ledView: LEDView
    private let engine: StateEngine

    private var scale: CGFloat = WidgetController.defaultScale
    private var currentState: StateEngine.DisplayState = .red

    private enum Prefs {
        static let scale = "trafficlight.widget.scale"
        static let originX = "trafficlight.widget.origin.x"
        static let originY = "trafficlight.widget.origin.y"
        static let hidden = "trafficlight.widget.hidden"
    }

    /// 画布宽高比（归一化资源为 732x271）
    private let aspect: CGFloat = 732.0 / 271.0
    private var baseSize: CGSize { CGSize(width: 120, height: 120 / aspect) }

    init(engine: StateEngine) {
        self.engine = engine
        let led = LEDView(frame: .zero)
        ledView = led
        panel = TrafficPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none

        ledView.imageScaling = .scaleProportionallyUpOrDown
        ledView.wantsLayer = true
        panel.contentView = ledView

        ledView.onScrollZoom = { [weak self] delta in self?.zoom(by: delta * 0.01) }
        ledView.onPinchZoom = { [weak self] delta in self?.zoom(by: delta) }
        ledView.onClick = { [weak self] in self?.handleClick() }
        ledView.onDoubleClick = { [weak self] in self?.resetZoom() }

        restoreFrame()
    }

    // MARK: - 显示

    func show() {
        panel.orderFrontRegardless()
        applyState(currentState)
    }

    func setIsHidden(_ hidden: Bool) {
        hidden ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    var isHidden: Bool { !panel.isVisible }

    // MARK: - 状态展示

    func applyState(_ state: StateEngine.DisplayState) {
        currentState = state
        let image = WidgetAssets.image(for: state)
        if ledView.image !== image {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.25
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ledView.layer?.add(transition, forKey: "swap")
            ledView.image = image
        }
        applyPulse(for: state)
        ledView.toolTip = tooltipText()
    }

    /// 定时刷新 tooltip（心跳秒数等），不改状态
    func refreshTooltip() {
        ledView.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        var lines = ["TrafficLight · \(engine.statusLine)"]
        for task in engine.tasks.prefix(5) {
            lines.append("● \(task.name)")
        }
        if engine.tasks.count > 5 { lines.append("… 共 \(engine.tasks.count) 个") }
        lines.append("拖动移动 · 滚轮缩放 · 双击复原")
        return lines.joined(separator: "\n")
    }

    private func applyPulse(for state: StateEngine.DisplayState) {
        ledView.layer?.removeAnimation(forKey: "pulse")
        let pulse: CABasicAnimation?
        switch state {
        case .green:
            // 完成待确认：明显呼吸，提示可点击
            pulse = Self.makePulse(from: 1.0, to: 0.7, duration: 1.0)
        case .orange:
            // 工作中：缓慢轻微呼吸
            pulse = Self.makePulse(from: 1.0, to: 0.87, duration: 1.8)
        case .red:
            pulse = nil
        }
        if let pulse { ledView.layer?.add(pulse, forKey: "pulse") }
    }

    private static func makePulse(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        return anim
    }

    // MARK: - 缩放与位置

    func zoom(by delta: CGFloat) {
        let newScale = min(max(scale + delta, Self.minScale), Self.maxScale)
        guard abs(newScale - scale) > 0.0001 else { return }
        scale = newScale
        applyFrame(keepingCenter: true)
        UserDefaults.standard.set(scale, forKey: Prefs.scale)
    }

    func resetZoom() {
        scale = Self.defaultScale
        applyFrame(keepingCenter: true)
        UserDefaults.standard.set(scale, forKey: Prefs.scale)
    }

    func setScalePreset(_ preset: Int) {
        // 0=小 1=中 2=大
        scale = [0.65, 1.0, 1.6][min(max(preset, 0), 2)]
        applyFrame(keepingCenter: true)
        UserDefaults.standard.set(scale, forKey: Prefs.scale)
    }

    var scalePreset: Int {
        if scale < 0.85 { return 0 }
        if scale > 1.25 { return 2 }
        return 1
    }

    func resetPosition() {
        panel.setFrameOrigin(defaultOrigin(for: currentSize()))
        saveOrigin()
    }

    private func currentSize() -> CGSize {
        let s = baseSize
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private func applyFrame(keepingCenter: Bool) {
        let size = currentSize()
        let oldFrame = panel.frame
        var origin = panel.frame.origin
        if keepingCenter {
            origin.x = oldFrame.midX - size.width / 2
            origin.y = oldFrame.midY - size.height / 2
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func defaultOrigin(for size: CGSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 200, y: 200) }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - 28,
                       y: visible.maxY - size.height - 20)
    }

    private func restoreFrame() {
        let savedScale = UserDefaults.standard.double(forKey: Prefs.scale)
        scale = savedScale > 0 ? savedScale : Self.defaultScale

        let size = currentSize()
        var origin: NSPoint
        let x = UserDefaults.standard.double(forKey: Prefs.originX)
        let y = UserDefaults.standard.double(forKey: Prefs.originY)
        let hasSaved = x != 0 || y != 0
        origin = NSPoint(x: x, y: y)
        if !hasSaved || !isVisibleOnAnyScreen(NSRect(origin: origin, size: size)) {
            origin = defaultOrigin(for: size)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func isVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func saveOrigin() {
        UserDefaults.standard.set(panel.frame.origin.x, forKey: Prefs.originX)
        UserDefaults.standard.set(panel.frame.origin.y, forKey: Prefs.originY)
    }

    // MARK: - 交互

    private func handleClick() {
        guard engine.displayState == .green else { return }
        engine.handle(TLRequest(cmd: "ack", id: engine.pendingCompletion?.id))
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveOrigin()
    }
}

// MARK: -

/// 无边框悬浮面板：不抢焦点，可点击
final class TrafficPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 承载红绿灯图片的视图，处理滚轮/捏合/点击手势
final class LEDView: NSImageView {
    var onScrollZoom: ((CGFloat) -> Void)?
    var onPinchZoom: ((CGFloat) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var mouseDownPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScrollZoom?(event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onPinchZoom?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)   // 保留窗口拖动能力
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            super.mouseUp(with: event)
        }
        guard let down = mouseDownPoint else { return }
        let up = event.locationInWindow
        guard hypot(down.x - up.x, down.y - up.y) < 4 else { return }   // 拖动不算点击
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }
}
