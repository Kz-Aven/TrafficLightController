import AppKit
import TrafficLightCore

/// 悬浮红绿灯窗口（桌面宠物式交互）：
/// - 拖动窗口任意位置移动（原生 performDrag，完全贴合鼠标、无阻滞）
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
        // 不用背景拖动（边框窗 + 自定义 contentView + nonactivatingPanel 下不可靠），
        // 改为 LEDView 显式 mouseDragged 拖动窗口
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none

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
        let art = WidgetAssets.art(for: state)
        // 静态显示亮帧（CGImage 直接交给 displayLayer，不走 NSImageView 内部绘制，
        // 否则叠加在 displayLayer 上的 contents 帧动画会被 AppKit 重绘覆盖 → 长亮不闪）
        let cg = art.litCG ?? art.display.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if ledView.displayCG !== cg {
            ledView.displayCG = cg
        }
        applyPulse(for: state, art: art)
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

    private func applyPulse(for state: StateEngine.DisplayState, art: StateArt) {
        ledView.setPulse(nil)
        switch state {
        case .green:
            // 完成待确认：圆内颜色呼吸（亮↔半亮），外框静止
            if let lit = art.litCG, let half = art.halfCG {
                ledView.setPulse(Self.makeContentsBreathe(lit: lit, dim: half))
            } else {
                ledView.setPulse(Self.makePulse(from: 1.0, to: 0.7, duration: 1.0))
            }
        case .orange:
            // 工作中：圆内颜色明显闪烁（亮↔灭），外框静止
            if let lit = art.litCG, let off = art.offCG {
                ledView.setPulse(Self.makeContentsBlink(lit: lit, dim: off))
            } else {
                ledView.setPulse(Self.makeBlink(cycle: 1.0, onFraction: 0.5))
            }
        case .red:
            break   // 静态
        }
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

    /// 闪烁（contents 双帧）：一个周期内"亮帧→保持→灭帧→保持"，
    /// 两帧边框像素一致，外框完全不动。过渡段为快速交叉淡入淡出。
    /// - Parameters:
    ///   - cycle: 一个完整亮灭周期的时长（秒）。默认 1.0（约每秒闪一次）。
    ///   - onFraction: 周期内"亮"占比（0~1），其余时间为灭。默认 0.5。
    private static func makeContentsBlink(lit: CGImage, dim: CGImage,
                                          cycle: CFTimeInterval = 1.0,
                                          onFraction: CGFloat = 0.5) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "contents")
        let holdOnEnd = onFraction * 0.85
        let offStart  = onFraction + (1 - onFraction) * 0.15
        anim.values = [lit, lit, dim, dim]
        anim.keyTimes = [NSNumber(value: 0.0),
                         NSNumber(value: Double(holdOnEnd)),
                         NSNumber(value: Double(offStart)),
                         NSNumber(value: 1.0)]
        anim.duration = cycle
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        return anim
    }

    /// 呼吸（contents 双帧）：亮帧 ↔ 半亮帧 往复，边框静止
    private static func makeContentsBreathe(lit: CGImage, dim: CGImage,
                                            duration: CFTimeInterval = 1.0) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = [lit, dim, lit]
        anim.keyTimes = [NSNumber(value: 0.0), NSNumber(value: 0.5), NSNumber(value: 1.0)]
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        return anim
    }

    /// opacity 闪烁：拆分失败时的兜底（整图闪烁）
    private static func makeBlink(cycle: CFTimeInterval = 1.0,
                                  onFraction: CGFloat = 0.5) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        let holdOnEnd = onFraction * 0.85          // 全亮保持到周期的前 85%*onFraction
        let offStart  = onFraction + (1 - onFraction) * 0.15  // 之后快速切到全灭
        anim.values = [1.0, 1.0, 0.0, 0.0]
        anim.keyTimes = [NSNumber(value: 0.0),
                         NSNumber(value: Double(holdOnEnd)),
                         NSNumber(value: Double(offStart)),
                         NSNumber(value: 1.0)]
        anim.duration = cycle
        anim.repeatCount = .infinity
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

/// 承载红绿灯图片的视图（NSView，不使用 NSImageView 内置绘制）：
/// - 自己持有一个 displayLayer，图片内容与动画都由我们独占控制，
///   不会被 AppKit 重绘覆盖（这是之前 contents 帧动画"长亮不闪"的根因）
/// - 处理滚轮 / 捏合 / 点击手势
final class LEDView: NSView {
    var onScrollZoom: ((CGFloat) -> Void)?
    var onPinchZoom: ((CGFloat) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 我们独占的显示层：contents 设为 CGImage，contents 帧动画也加在它上面
    private let displayLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDisplayLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDisplayLayer()
    }

    private func setupDisplayLayer() {
        wantsLayer = true
        displayLayer.contentsGravity = .resize
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
    }

    /// 静态显示内容（CGImage）；nil 表示清空。
    /// 另用私有属性同步持有，避免对 layer.contents（Any?）做 CGImage 强转产生告警。
    private var _displayCG: CGImage?
    var displayCG: CGImage? {
        get { _displayCG }
        set {
            _displayCG = newValue
            displayLayer.contents = newValue
        }
    }

    /// 添加 / 移除显示层上的动画（闪烁 / 呼吸）。nil 表示移除。
    /// 动画加在我们自有图层上，AppKit 不会覆盖。
    func setPulse(_ anim: CAAnimation?) {
        displayLayer.removeAnimation(forKey: "pulse")
        if let anim { displayLayer.add(anim, forKey: "pulse") }
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScrollZoom?(event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onPinchZoom?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        let originBefore = window?.frame.origin ?? .zero
        // 原生窗口拖动：由窗口服务器直接跟随光标，无阻滞感。
        // 对 nonactivatingPanel 这类无法成为 key 的面板，这是官方推荐的拖动方式，
        // 比手动 mouseDragged + setFrameOrigin 更顺滑、完全贴合鼠标。
        window?.performDrag(with: event)
        // 拖动结束后，若窗口未发生移动则判定为点击（区分单击 / 双击）
        let originAfter = window?.frame.origin ?? .zero
        guard hypot(originAfter.x - originBefore.x,
                    originAfter.y - originBefore.y) < 5 else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else if event.clickCount == 1 {
            onClick?()
        }
    }
}
