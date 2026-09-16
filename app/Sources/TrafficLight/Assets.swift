import AppKit

/// 加载红绿灯图片资源；若 bundle 中缺失则回退为程序化绘制，
/// 保证 App 在任何情况下都能显示。
enum WidgetAssets {

    private static var cache: [StateEngine.DisplayState: NSImage] = [:]
    private static var loaded = false

    static func image(for state: StateEngine.DisplayState) -> NSImage {
        loadIfNeeded()
        return cache[state] ?? fallbackImage(for: state)
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let mapping: [(StateEngine.DisplayState, String)] = [
            (.red, "red"), (.orange, "yellow"), (.green, "green"),
        ]
        for (state, name) in mapping {
            if let img = bundled(name) {
                cache[state] = img
            }
        }
    }

    /// 优先主 bundle（组装后的 .app），其次 SPM 资源 bundle（swift run 场景）
    private static func bundled(_ name: String) -> NSImage? {
        if let img = Bundle.main.image(forResource: NSImage.Name(name)), img.isValid {
            return img
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url), img.isValid {
            return img
        }
        return nil
    }

    // MARK: - 程序化回退（资源缺失时）

    private static func fallbackImage(for state: StateEngine.DisplayState) -> NSImage {
        let size = NSSize(width: 732, height: 271)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let pill = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 720, height: 259), xRadius: 129, yRadius: 129)
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
        pill.fill()

        let bulbs: [(NSColor, StateEngine.DisplayState)] = [
            (NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.13, alpha: 1), .red),
            (NSColor(calibratedRed: 0.95, green: 0.63, blue: 0.08, alpha: 1), .orange),
            (NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.42, alpha: 1), .green),
        ]
        for (index, bulb) in bulbs.enumerated() {
            let cx = 130.0 + CGFloat(index) * 236.0
            let lit = bulb.1 == state
            let radius: CGFloat = lit ? 96 : 88
            let dot = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: 135.5 - radius,
                                                  width: radius * 2, height: radius * 2))
            (lit ? bulb.0 : NSColor(calibratedWhite: 0.22, alpha: 1)).setFill()
            dot.fill()
        }
        img.unlockFocus()
        return img
    }
}
