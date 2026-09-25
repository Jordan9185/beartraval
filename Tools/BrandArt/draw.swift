import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func canvas(_ w: Int, _ h: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // 左上為原點
    ctx.setShouldAntialias(true)
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func ellipse(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
    c.setFillColor(color); c.fillEllipse(in: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
}
func circle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) { ellipse(c, x, y, r * 2, r * 2, color) }

let fur = rgb(0x9A6440), furDark = rgb(0x7A4A2E), muzzle = rgb(0xF1D7B5), innerEar = rgb(0xE3A889)
let ink = rgb(0x3A2418), cheek = rgb(0xFF8F8F, 0.55)
let hatYellow = rgb(0xF6B83C), hatShade = rgb(0xE09A1C), band = rgb(0xE4572E)

/// 戴探險帽的熊熊頭；s = 頭的半徑。
func bear(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) {
    // 耳朵
    for dx in [-0.74, 0.74] as [CGFloat] {
        circle(c, cx + dx * s, cy - 0.66 * s, 0.34 * s, fur)
        circle(c, cx + dx * s, cy - 0.66 * s, 0.19 * s, innerEar)
    }
    // 頭（下方加一點陰影）
    circle(c, cx, cy + 0.03 * s, s, furDark)
    circle(c, cx, cy, s, fur)
    // 口鼻
    ellipse(c, cx, cy + 0.36 * s, 0.98 * s, 0.7 * s, muzzle)
    ellipse(c, cx, cy + 0.2 * s, 0.34 * s, 0.24 * s, ink)
    ellipse(c, cx - 0.05 * s, cy + 0.15 * s, 0.1 * s, 0.06 * s, rgb(0xFFFFFF, 0.6))
    // 嘴
    c.setStrokeColor(ink); c.setLineWidth(0.05 * s); c.setLineCap(.round)
    c.move(to: CGPoint(x: cx, y: cy + 0.31 * s)); c.addLine(to: CGPoint(x: cx, y: cy + 0.42 * s))
    c.addArc(center: CGPoint(x: cx - 0.11 * s, y: cy + 0.42 * s), radius: 0.11 * s, startAngle: 0, endAngle: .pi * 0.9, clockwise: false)
    c.move(to: CGPoint(x: cx, y: cy + 0.42 * s))
    c.addArc(center: CGPoint(x: cx + 0.11 * s, y: cy + 0.42 * s), radius: 0.11 * s, startAngle: .pi, endAngle: .pi * 0.1, clockwise: true)
    c.strokePath()
    // 眼睛與腮紅
    for dx in [-0.38, 0.38] as [CGFloat] {
        circle(c, cx + dx * s, cy - 0.08 * s, 0.1 * s, ink)
        circle(c, cx + dx * s + 0.03 * s, cy - 0.11 * s, 0.035 * s, rgb(0xFFFFFF))
        ellipse(c, cx + dx * 1.62 * s, cy + 0.22 * s, 0.26 * s, 0.16 * s, cheek)
    }
    // 探險帽：帽簷、帽身、帽帶
    ellipse(c, cx, cy - 0.7 * s, 1.5 * s, 0.3 * s, hatShade)
    ellipse(c, cx, cy - 0.73 * s, 1.44 * s, 0.24 * s, hatYellow)
    let crown = CGRect(x: cx - 0.5 * s, y: cy - 1.22 * s, width: 1.0 * s, height: 0.56 * s)
    c.setFillColor(hatYellow)
    c.addPath(CGPath(roundedRect: crown, cornerWidth: 0.34 * s, cornerHeight: 0.3 * s, transform: nil)); c.fillPath()
    c.setFillColor(band); c.fill(CGRect(x: cx - 0.5 * s, y: cy - 0.86 * s, width: 1.0 * s, height: 0.12 * s))
}

/// 小飛機（朝右上）。
func plane(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat, angle: CGFloat) {
    c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: angle)
    c.setFillColor(rgb(0xFFFFFF))
    c.addPath(CGPath(roundedRect: CGRect(x: -s, y: -0.16 * s, width: 2 * s, height: 0.32 * s), cornerWidth: 0.16 * s, cornerHeight: 0.16 * s, transform: nil))
    c.fillPath()
    let wing = CGMutablePath()
    wing.move(to: CGPoint(x: 0.25 * s, y: 0)); wing.addLine(to: CGPoint(x: -0.35 * s, y: -0.95 * s))
    wing.addLine(to: CGPoint(x: -0.6 * s, y: -0.95 * s)); wing.addLine(to: CGPoint(x: -0.25 * s, y: 0))
    wing.addLine(to: CGPoint(x: -0.6 * s, y: 0.95 * s)); wing.addLine(to: CGPoint(x: -0.35 * s, y: 0.95 * s)); wing.closeSubpath()
    c.addPath(wing); c.fillPath()
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: -0.75 * s, y: 0)); tail.addLine(to: CGPoint(x: -1.0 * s, y: -0.42 * s))
    tail.addLine(to: CGPoint(x: -1.12 * s, y: -0.42 * s)); tail.addLine(to: CGPoint(x: -0.98 * s, y: 0))
    tail.addLine(to: CGPoint(x: -1.12 * s, y: 0.42 * s)); tail.addLine(to: CGPoint(x: -1.0 * s, y: 0.42 * s)); tail.closeSubpath()
    c.addPath(tail); c.fillPath()
    c.restoreGState()
}

// MARK: App 圖示 1024×1024（不透明，iOS 會自動裁圓角）
// 樣式指南：不用漸層與裝飾（天空、太陽、雲、航線在小尺寸會變雜點），只留熊熊與單一暖色底。
let icon = canvas(1024, 1024, opaque: true) { c in
    c.setFillColor(rgb(0xFFF1D6))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    bear(c, 512, 560, 340)
}
save(icon, "AppIcon.png")

// MARK: 啟動畫面：熊熊坐在行李箱上 + 字樣（透明背景，3x）
let launchW = 720, launchH = 900
let launch = canvas(launchW, launchH, opaque: false) { c in
    let cx: CGFloat = 360
    // 行李箱
    c.setFillColor(rgb(0x1F7FA8))
    c.addPath(CGPath(roundedRect: CGRect(x: cx - 70, y: 360, width: 140, height: 60), cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.setStrokeColor(rgb(0x1F7FA8)); c.setLineWidth(22); c.strokePath()
    c.setFillColor(rgb(0x2E9CCA))
    c.addPath(CGPath(roundedRect: CGRect(x: cx - 200, y: 400, width: 400, height: 260), cornerWidth: 40, cornerHeight: 40, transform: nil)); c.fillPath()
    c.setFillColor(rgb(0x1F7FA8)); c.fill(CGRect(x: cx - 200, y: 510, width: 400, height: 22))
    // 貼紙
    circle(c, cx - 120, 600, 34, rgb(0xE4572E)); circle(c, cx + 120, 590, 30, rgb(0xF6B83C))
    c.setFillColor(rgb(0xFFFFFF)); c.addPath(CGPath(roundedRect: CGRect(x: cx + 30, y: 440, width: 110, height: 44), cornerWidth: 10, cornerHeight: 10, transform: nil)); c.fillPath()
    // 輪子
    circle(c, cx - 140, 675, 22, rgb(0x33424D)); circle(c, cx + 140, 675, 22, rgb(0x33424D))
    // 熊熊（頭 + 小手搭在行李箱上）
    circle(c, cx - 150, 420, 42, fur); circle(c, cx + 150, 420, 42, fur)
    bear(c, cx, 250, 175)
    // 字樣
    let font = NSFont.systemFont(ofSize: 110, weight: .heavy)
    let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 110) ?? font
    let text = NSAttributedString(string: "BeaRTravel", attributes: [.font: rounded, .foregroundColor: NSColor(cgColor: rgb(0x9A6440))!])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    let size = text.size()
    text.draw(at: CGPoint(x: cx - size.width / 2, y: 740))
    NSGraphicsContext.restoreGraphicsState()
}
save(launch, "LaunchLogo@3x.png")
