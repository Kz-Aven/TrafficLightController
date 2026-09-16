import AppKit

/// 单个状态的艺术资源（"框不动、只动圆"方案）：
/// 所有动画帧共享同一张"全灰底框"（offCG），亮帧/半亮帧只是把
/// 对应灯座的亮灯方块贴回底框。方块之外的区域逐位一致，
/// 因此闪烁/呼吸时外框与相邻熄灭灯纹丝不动，颜色完全保真。
struct StateArt {
    /// 静态显示整图（= litCG 的 NSImage），NSImageView 与弹窗图标共用
    let display: NSImage
    /// 亮帧：全灰底框 + 亮灯圆
    let litCG: CGImage?
    /// 半亮帧：全灰底框 + 50% 亮灯圆（呼吸低点）
    let halfCG: CGImage?
    /// 灭帧：全灰底框（所有灯熄灭）
    let offCG: CGImage?
}

/// 加载红绿灯图片资源；若 bundle 中缺失或帧构建失败，
/// 回退为程序化绘制 + opacity 动画，保证 App 在任何情况下都能显示。
enum WidgetAssets {

    private static var cache: [StateEngine.DisplayState: StateArt] = [:]
    private static var loaded = false

    static func art(for state: StateEngine.DisplayState) -> StateArt {
        loadIfNeeded()
        if let art = cache[state] { return art }
        let fb = fallbackImage(for: state)
        let cg = fb.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return StateArt(display: fb, litCG: cg, halfCG: nil, offCG: nil)
    }

    /// 整灯亮图，供弹窗图标等场景使用
    static func image(for state: StateEngine.DisplayState) -> NSImage {
        art(for: state).display
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard
            let redImg = bundled("red"), let yellowImg = bundled("yellow"), let greenImg = bundled("green"),
            let redCG = redImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let yellowCG = yellowImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let greenCG = greenImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let frames = buildFrames(red: (redImg.size, redCG),
                                     yellow: (yellowImg.size, yellowCG),
                                     green: (greenImg.size, greenCG))
        else { return }
        cache[.red] = frames.red
        cache[.orange] = frames.orange
        cache[.green] = frames.green
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

    // MARK: - 帧构建（共享底框 + 灯座方块合成）

    private typealias LitBulb = (center: CGPoint, radius: CGFloat)

    /// 由三张归一化合成图（画布一致、仅亮灯位置不同）构建各状态帧：
    /// 1) 分别检测各图亮灯圆的中心与光晕半径（高饱和像素扫描）
    /// 2) 全灰底框 = 黄图为底，把中间亮灯座替换为红图中同位置的灰色熄灭灯
    /// 3) 各状态亮帧 = 底框 + 该图亮灯方块；半亮帧 = 底框 + 50% 亮灯方块
    private static func buildFrames(red: (NSSize, CGImage),
                                    yellow: (NSSize, CGImage),
                                    green: (NSSize, CGImage)) -> (red: StateArt, orange: StateArt, green: StateArt)? {
        let yellowCG = yellow.1
        let w = yellowCG.width, h = yellowCG.height
        guard red.1.width == w, red.1.height == h, green.1.width == w, green.1.height == h,
              w > 16, h > 16 else { return nil }
        guard let redLit = litBulb(red.1),
              let yellowLit = litBulb(yellowCG),
              let greenLit = litBulb(green.1) else { return nil }

        // 灯座间距（红、绿为两端灯座），用于估计红图中"中间灯座"的位置
        let spacing = (greenLit.center.x - redLit.center.x) / 2
        guard spacing > 10 else { return nil }
        let socket2InRed = CGPoint(x: redLit.center.x + spacing, y: redLit.center.y)

        // 全灰底框：黄图为底，中间亮灯方块替换为红图的灰灯方块
        let coverSide = Int(2 * yellowLit.radius + 20)
        guard let offCtx = makeContext(width: w, height: h),
              let grayPatch = crop(red.1, center: socket2InRed, side: coverSide) else { return nil }
        offCtx.interpolationQuality = .none
        offCtx.draw(yellowCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        offCtx.draw(grayPatch, in: pasteRect(center: socket2InRed, side: coverSide))
        guard let offCG = offCtx.makeImage() else { return nil }

        func makeState(_ src: (NSSize, CGImage), lit: LitBulb) -> StateArt? {
            let side = Int(2 * lit.radius + 16)
            guard let litCtx = makeContext(width: w, height: h),
                  let halfCtx = makeContext(width: w, height: h),
                  let patch = crop(src.1, center: lit.center, side: side) else { return nil }
            for ctx in [litCtx, halfCtx] {
                ctx.interpolationQuality = .none
                ctx.draw(offCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let rect = pasteRect(center: lit.center, side: side)
            litCtx.draw(patch, in: rect)
            halfCtx.setAlpha(0.5)
            halfCtx.draw(patch, in: rect)
            guard let litCG = litCtx.makeImage(), let halfCG = halfCtx.makeImage() else { return nil }
            return StateArt(display: NSImage(cgImage: litCG, size: src.0),
                            litCG: litCG, halfCG: halfCG, offCG: offCG)
        }

        guard let r = makeState(red, lit: redLit),
              let o = makeState(yellow, lit: yellowLit),
              let g = makeState(green, lit: greenLit) else { return nil }
        return (r, o, g)
    }

    /// 扫描高饱和像素定位亮灯圆（外框与熄灭灯均为低饱和灰黑，不会误判）
    private static func litBulb(_ cg: CGImage) -> LitBulb? {
        let w = cg.width, h = cg.height
        guard w > 16, h > 16, let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                let mx = max(r, g, b), mn = min(r, g, b)
                if mx - mn > 40, mx > 60 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let center = CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)
        let radius = CGFloat(max(maxX - minX, maxY - minY)) / 2 + 8
        return (center, radius)
    }

    /// 从源图裁出以 center 为中心、边长 side 的方块（1:1 偏移绘制，坐标系一致无需翻转）
    private static func crop(_ src: CGImage, center: CGPoint, side: Int) -> CGImage? {
        guard side > 0, let ctx = makeContext(width: side, height: side) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: -(center.x - CGFloat(side) / 2),
                                 y: -(center.y - CGFloat(side) / 2),
                                 width: CGFloat(src.width), height: CGFloat(src.height)))
        return ctx.makeImage()
    }

    private static func pasteRect(center: CGPoint, side: Int) -> CGRect {
        CGRect(x: center.x - CGFloat(side) / 2, y: center.y - CGFloat(side) / 2,
               width: CGFloat(side), height: CGFloat(side))
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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
