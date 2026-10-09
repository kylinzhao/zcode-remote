// ZCode Remote macOS 应用图标渲染器（零依赖：swiftc 直接编译运行）
// 设计：与 ZCode 桌面端同族——深蓝渐变 squircle + 白色粗壮「Z」+ 右上角信号弧（remote 身份）。
// 用法：swiftc mac/tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/icon-1024.png
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024

func makeContext() -> CGContext {
    CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// macOS 风格超椭圆（squircle）路径。|x/a|^n + |y/b|^n = 1，n≈5 接近系统圆角手感。
func squircle(center: CGPoint, half: CGFloat, n: CGFloat) -> CGPath {
    let pts: [CGPoint] = (0...192).map { i in
        let t = CGFloat(i) / 192 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        return CGPoint(x: x, y: y)
    }
    let path = CGMutablePath()
    path.addLines(between: pts)
    path.closeSubpath()
    return path
}

let ctx = makeContext()
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 1. squircle 底板：外投影 + 斜向深蓝渐变（呼应 ZCode 桌面端 #1E2A78 → #0A0E23）
let body = squircle(center: CGPoint(x: 512, y: 512), half: 412, n: 5)
ctx.saveGState()
ctx.addPath(body); ctx.clip()
let colors = [
    CGColor(red: 0.16, green: 0.22, blue: 0.55, alpha: 1),  // 顶部亮蓝紫
    CGColor(red: 0.05, green: 0.06, blue: 0.18, alpha: 1),  // 底部近黑深蓝
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 250, y: 860), end: CGPoint(x: 800, y: 160), options: [])
// 顶部一圈微高光，增加立体感
ctx.setShadow(offset: .zero, blur: 0)
let hl = squircle(center: CGPoint(x: 512, y: 512), half: 412, n: 5)
ctx.addPath(hl)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 2. 白色粗壮「Z」：三段圆头粗线（不依赖字体，笔画完全可控）
let zStroke: [CGPoint] = [
    CGPoint(x: 300, y: 672), CGPoint(x: 610, y: 672),   // 上横
    CGPoint(x: 610, y: 672), CGPoint(x: 322, y: 336),   // 对角线
    CGPoint(x: 300, y: 336), CGPoint(x: 610, y: 336),   // 下横
]
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26,
              color: CGColor(red: 0, green: 0, blue: 0.1, alpha: 0.45))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(84)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addLines(between: zStroke)
ctx.strokePath()
ctx.restoreGState()

// 3. 右上角信号弧 + 圆点：remote 的身份符号，三道弧透明度递减
func arc(center: CGPoint, radius: CGFloat, startDeg: CGFloat, endDeg: CGFloat, alpha: CGFloat) {
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius,
               startAngle: startDeg * .pi / 180, endAngle: endDeg * .pi / 180, clockwise: false)
    ctx.strokePath()
}
let sig = CGPoint(x: 716, y: 716)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: sig.x - 24, y: sig.y - 24, width: 48, height: 48))
arc(center: sig, radius: 78, startDeg: 8, endDeg: 82, alpha: 0.92)
arc(center: sig, radius: 132, startDeg: 8, endDeg: 82, alpha: 0.60)
arc(center: sig, radius: 186, startDeg: 8, endDeg: 82, alpha: 0.30)

// 4. 导出 PNG
let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("written \(out.path)")
