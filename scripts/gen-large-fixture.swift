import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Generate a wide PNG of small mixed Chinese/English lines plus a sidecar of
// the exact strings drawn. The PNG is not committed.
//
//   swift scripts/gen-large-fixture.swift
//   swift scripts/gen-large-fixture.swift -o /tmp/large-ocr.png
//
// Default size is 7000×5000. The sidecar is the PNG path with a .txt extension.
// Each sidecar line is one drawn row. A line starts with L### and ends with E###.

let fontSize: CGFloat = 16
let lineHeight: CGFloat = 22
let margin: CGFloat = 40

func usage() {
    let text = """
    usage: swift scripts/gen-large-fixture.swift [-o path] [--width px] [--height px]

    Default output: fixtures/large-ocr.png and fixtures/large-ocr.txt
    Default size: 7000×5000, 16px glyphs, 200+ lines.

    """
    fputs(text, stdout)
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func makeColor(_ space: CGColorSpace, _ components: CGFloat...) -> CGColor {
    var values = components
    guard let color = CGColor(colorSpace: space, components: &values) else {
        fail("could not build colors")
    }
    return color
}

func resolveFont() -> (CTFont, String) {
    let names = ["PingFangSC-Regular", "HiraginoSansGB-W3", "SongtiSC-Regular", "STHeitiSC-Light", "Helvetica"]
    for name in names {
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        if actual == name {
            return (font, actual)
        }
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    return (font, CTFontCopyPostScriptName(font) as String)
}

func measure(_ text: String, font: CTFont) -> CGFloat {
    let attrs = [kCTFontAttributeName: font] as CFDictionary
    guard let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs) else {
        return .greatestFiniteMagnitude
    }
    let line = CTLineCreateWithAttributedString(string)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

func buildLine(index: Int, maxWidth: CGFloat, font: CTFont) -> String {
    let head = String(format: "L%03d ", index)
    let tail = String(format: " E%03d", index)
    let filler = "发票金额 Invoice 100 元 "
    var middle = ""
    while true {
        let candidate = head + middle + filler + tail
        if measure(candidate, font: font) > maxWidth { break }
        middle += filler
        if middle.count > 8000 { break }
    }
    return head + middle + tail
}

var output = "fixtures/large-ocr.png"
var width = 7000
var height = 5000
var cursor = 0
let arguments = Array(CommandLine.arguments.dropFirst())
while cursor < arguments.count {
    let arg = arguments[cursor]
    func needValue(_ name: String) -> String {
        cursor += 1
        guard cursor < arguments.count else { fail("missing value for \(name)") }
        return arguments[cursor]
    }
    if arg == "--help" || arg == "-h" {
        usage()
        exit(0)
    } else if arg == "-o" {
        output = needValue(arg)
    } else if arg == "--width" {
        guard let value = Int(needValue(arg)), value >= 64, value <= 20000 else {
            fail("--width must be 64...20000")
        }
        width = value
    } else if arg == "--height" {
        guard let value = Int(needValue(arg)), value >= 64, value <= 20000 else {
            fail("--height must be 64...20000")
        }
        height = value
    } else {
        fail("unknown argument \(arg); pass --help")
    }
    cursor += 1
}

let (font, fontName) = resolveFont()
let ascent = CTFontGetAscent(font)
let descent = CTFontGetDescent(font)
var baselines: [CGFloat] = []
var baseline = CGFloat(height) - margin - ascent
while baseline - descent >= margin {
    baselines.append(baseline)
    baseline -= lineHeight
}
if baselines.count < 200 {
    fail("only \(baselines.count) lines fit in \(height)px; use a taller image")
}

let maxTextWidth = CGFloat(width) - margin * 2
var rows: [String] = []
rows.reserveCapacity(baselines.count)
for index in 1...baselines.count {
    rows.append(buildLine(index: index, maxWidth: maxTextWidth, font: font))
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("could not allocate a \(width)x\(height) bitmap")
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
let white = makeColor(colorSpace, 1, 1, 1, 1)
let black = makeColor(colorSpace, 0, 0, 0, 1)
context.setFillColor(white)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
for (row, text) in zip(baselines, rows) {
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: black,
    ]
    guard let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary) else {
        fail("could not build line")
    }
    let line = CTLineCreateWithAttributedString(string)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: margin, y: row)
    CTLineDraw(line, context)
}

guard let image = context.makeImage() else { fail("could not read back the bitmap") }
let pngURL = URL(fileURLWithPath: output)
let directory = pngURL.deletingLastPathComponent()
if directory.path != "" && directory.path != "." {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        fail("could not create \(directory.path)")
    }
}
guard let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("could not create \(pngURL.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(pngURL.path)") }

let textURL = pngURL.deletingPathExtension().appendingPathExtension("txt")
let sidecar = rows.joined(separator: "\n") + "\n"
do {
    try sidecar.write(to: textURL, atomically: true, encoding: .utf8)
} catch {
    fail("could not write \(textURL.path)")
}

print("wrote \(pngURL.path) (\(width)x\(height)) and \(textURL.path) (\(rows.count) lines, font \(fontName))")
