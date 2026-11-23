// make_icon.swift — генерация иконки FanBar (1024×1024 PNG).
// swiftc make_icon.swift -o make_icon -framework AppKit && ./make_icon out.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "FanBar.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap") }
rep.size = NSSize(width: 1024, height: 1024)

NSGraphicsContext.saveGraphicsState()
guard let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

let center = CGPoint(x: 512, y: 520)

// ---------- фон: скруглённый квадрат с градиентом ----------
let bgRect = CGRect(x: 56, y: 56, width: 912, height: 912)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 205, cornerHeight: 205, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// вертикальный градиент: яркий синий сверху → тёмно-синий снизу
let bgGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0.16, 0.47, 0.96).cgColor, rgb(0.07, 0.16, 0.48).cgColor, rgb(0.03, 0.06, 0.20).cgColor] as CFArray,
    locations: [0, 0.6, 1]
)!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 968), end: CGPoint(x: 0, y: 56), options: [])

// глянцевый блик сверху
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(1, 1, 1, 0.30).cgColor, rgb(1, 1, 1, 0.0).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 968), end: CGPoint(x: 0, y: 560), options: [])

// циановое свечение вокруг вентилятора
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0.35, 0.93, 0.97, 0.42).cgColor, rgb(0.35, 0.93, 0.97, 0.0).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 40,
                       endCenter: center, endRadius: 430,
                       options: [.drawsBeforeStartLocation])

ctx.restoreGState()

// ---------- кольцо (штрихи = движение) ----------
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
ctx.setStrokeColor(rgb(1, 1, 1, 0.16).cgColor)
ctx.setLineWidth(7)
ctx.setLineDash(phase: 0, lengths: [3, 34])
ctx.strokeEllipse(in: CGRect(x: center.x - 408, y: center.y - 408, width: 816, height: 816))
ctx.setLineDash(phase: 0, lengths: [])
ctx.restoreGState()

// ---------- лопасти ----------
func bladePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 82, y: -52))
    p.addCurve(to: CGPoint(x: 392, y: -128),
               control1: CGPoint(x: 196, y: -246),
               control2: CGPoint(x: 318, y: -252))
    p.addCurve(to: CGPoint(x: 410, y: 34),
               control1: CGPoint(x: 428, y: -74),
               control2: CGPoint(x: 432, y: -18))
    p.addCurve(to: CGPoint(x: 104, y: 92),
               control1: CGPoint(x: 330, y: 88),
               control2: CGPoint(x: 226, y: 84))
    p.closeSubpath()
    return p
}

func drawBlade(rotation: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotation)
    ctx.setAlpha(alpha)

    let path = bladePath()
    ctx.addPath(path)
    ctx.saveGState()
    ctx.clip()

    // радиальный градиент от ступицы к кончику лопасти
    let bladeGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(1.0, 1.0, 1.0).cgColor, rgb(0.72, 0.97, 1.0).cgColor, rgb(0.24, 0.85, 0.93).cgColor] as CFArray,
        locations: [0, 0.45, 1]
    )!
    ctx.drawRadialGradient(bladeGrad, startCenter: .zero, startRadius: 60,
                           endCenter: .zero, endRadius: 440,
                           options: [.drawsAfterEndLocation])

    // тонкая тень по контуру для объёма
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0.04, 0.10, 0.30, 0.35).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()

    ctx.restoreGState()
}

// полупрозрачные «призраки» — шлейф вращения
for i in 0..<4 {
    drawBlade(rotation: .pi / 2 * CGFloat(i) + .pi / 4, alpha: 0.14)
}
// основные лопасти
for i in 0..<4 {
    drawBlade(rotation: .pi / 2 * CGFloat(i), alpha: 1.0)
}

// ---------- ступица ----------
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)

// тень ступицы
ctx.setFillColor(rgb(0.02, 0.05, 0.16, 0.45).cgColor)
ctx.fillEllipse(in: CGRect(x: -126, y: -126, width: 252, height: 252))

// внешнее кольцо
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: -120, y: -120, width: 240, height: 240))
ctx.clip()
let hubOuter = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(1, 1, 1).cgColor, rgb(0.78, 0.84, 0.93).cgColor, rgb(0.55, 0.63, 0.78).cgColor] as CFArray,
    locations: [0, 0.7, 1]
)!
ctx.drawRadialGradient(hubOuter, startCenter: CGPoint(x: -40, y: 50), startRadius: 10,
                       endCenter: .zero, endRadius: 120,
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// внутреннее ядро: сплошной металлический диск (без тёмного «зрачка»)
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: -58, y: -58, width: 116, height: 116))
ctx.clip()
let hubInner = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0.97, 0.98, 1.0).cgColor, rgb(0.82, 0.88, 0.96).cgColor, rgb(0.68, 0.76, 0.90).cgColor] as CFArray,
    locations: [0, 0.6, 1]
)!
ctx.drawRadialGradient(hubInner, startCenter: CGPoint(x: -18, y: 24), startRadius: 5,
                       endCenter: .zero, endRadius: 60,
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// тонкий контур ядра
ctx.addEllipse(in: CGRect(x: -58, y: -58, width: 116, height: 116))
ctx.setStrokeColor(rgb(0.35, 0.44, 0.62, 0.6).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

ctx.restoreGState()

// ---------- рамка ----------
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.22).cgColor)
ctx.setLineWidth(5)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("written \(outPath)")
