// 归一化三张设计图：裁掉透明边缘、统一缩放与画布比例，
// 消除三张 AI 生成图之间的尺寸差异导致的切换抖动。
//
// 用法: swift scripts/normalize_assets.swift <raw目录> <输出目录>
// 输入: red.png / yello.png / green.png
// 输出: red.png / yellow.png / green.png（画布完全一致，仅亮灯位置不同）

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("用法: swift normalize_assets.swift <raw目录> <输出目录>\n".data(using: .utf8)!)
    exit(2)
}
let rawDir = args[1], outDir = args[2]

let sources = [("red.png", "red.png"), ("yello.png", "yellow.png"), ("green.png", "green.png")]
let contentWidth = 720.0   // 统一内容宽度（像素）
let pad = 6.0              // 画布四周留白

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// 计算非透明内容包围盒（alpha 阈值 20）
func contentBox(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            if px[(y * w + x) * 4 + 3] > 20 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX else { return .zero }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var cropped: [(String, CGImage, CGFloat)] = []
for (inName, outName) in sources {
    let img = loadImage(rawDir + "/" + inName)
    guard let img else { FileHandle.standardError.write("无法读取 \(inName)\n".data(using: .utf8)!); exit(1) }
    let box = contentBox(img)
    guard box.width > 0 else { FileHandle.standardError.write("\(inName) 内容为空\n".data(using: .utf8)!); exit(1) }
    let cut = img.cropping(to: box)!
    cropped.append((outName, cut, box.height / box.width))
    print("  \(inName) -> \(outName): 原始 \(img.width)x\(img.height)，内容 \(Int(box.width))x\(Int(box.height))")
}

// 画布高度取各图等比缩放后的最大值，保证三张图胶囊大小一致
let scaledList = cropped.map { (name: $0.0, img: $0.1, h: contentWidth * $0.2) }
let canvasH = scaledList.map { $0.h }.max()!
let canvasW = contentWidth + pad * 2
let canvasHFull = canvasH + pad * 2
print("  统一画布: \(Int(canvasW))x\(Int(canvasHFull))")

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for item in scaledList {
    let ctx = CGContext(data: nil, width: Int(canvasW), height: Int(canvasHFull),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // 垂直居中
    let drawY = (canvasHFull - item.h) / 2
    ctx.draw(item.img, in: CGRect(x: pad, y: drawY, width: contentWidth, height: item.h))
    let out = ctx.makeImage()!
    let url = URL(fileURLWithPath: outDir + "/" + item.name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("  写出 \(item.name)")
}
print("✅ 资源归一化完成")
