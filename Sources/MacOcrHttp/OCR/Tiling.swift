import CoreGraphics
import Foundation
import LineMergeCore

/// Fixed grid, not a recursive split. `scale=auto` probes the page once, at a
/// long side of at most 4096, and tiles the original bitmap only when the
/// glyphs are small. Tiles run one after another on the caller's worker.
enum TilePlan {
    static let tileLength = 2048
    static let overlap = 256

    struct Rect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    static func rects(width: Int, height: Int) -> [Rect] {
        let xs = spans(length: width)
        let ys = spans(length: height)
        var result: [Rect] = []
        result.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs {
                result.append(Rect(x: x.offset, y: y.offset, width: x.length, height: y.length))
            }
        }
        return result
    }

    static func spans(length: Int) -> [(offset: Int, length: Int)] {
        if length <= tileLength {
            return [(0, max(length, 0))]
        }
        let step = tileLength - overlap
        var offsets = [0]
        var cursor = 0
        while cursor + tileLength < length {
            let next = cursor + step
            let last = length - tileLength
            if next >= last {
                if last > offsets[offsets.count - 1] {
                    offsets.append(last)
                }
                break
            }
            offsets.append(next)
            cursor = next
        }
        return offsets.map { ($0, tileLength) }
    }
}

enum ImageOCR {
    static func recognize(
        decoded: DecodedImage,
        languages: [String],
        level: RecognitionLevel,
        scale: ScaleMode,
        script: ScriptMode,
        started: Date,
        minGlyphFrac: Double,
        force: TileForce?
    ) throws -> OCRPayload {
        let bitmapWidth = decoded.image.width
        let bitmapHeight = decoded.image.height
        let scaleX = Double(decoded.originalWidth) / Double(max(bitmapWidth, 1))
        let scaleY = Double(decoded.originalHeight) / Double(max(bitmapHeight, 1))
        if scale == .auto {
            return try recognizeAuto(
                decoded: decoded,
                languages: languages,
                level: level,
                script: script,
                started: started,
                minGlyphFrac: minGlyphFrac,
                force: force,
                scaleX: scaleX,
                scaleY: scaleY
            )
        }
        let tile = scale == .tile || (scale == .none && (bitmapWidth > TilePlan.tileLength || bitmapHeight > TilePlan.tileLength))
        let whole = TilePlan.Rect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
        let rects = tile ? TilePlan.rects(width: bitmapWidth, height: bitmapHeight) : [whole]
        let pass = try collect(
            rects: rects,
            bitmapWidth: bitmapWidth,
            bitmapHeight: bitmapHeight,
            languages: languages,
            level: level,
            image: decoded.image,
            scaleX: scaleX,
            scaleY: scaleY
        )
        let measured = TilePolicy.measure(
            width: decoded.originalWidth,
            height: decoded.originalHeight,
            lines: glyphBoxes(pass.lines)
        )
        let choice = TileChoice(
            mode: rects.count > 1 ? "tiled" : "whole",
            glyphPx: measured.glyphPx,
            glyphFrac: measured.glyphFrac,
            countedLines: measured.countedLines,
            tileDecision: "scale=\(scale.rawValue)"
        )
        return payload(
            decoded: decoded,
            scale: scale,
            script: script,
            started: started,
            lines: pass.lines,
            frames: pass.frames,
            echo: pass.echo,
            tiles: rects.count,
            choice: choice
        )
    }

    /// Probe at a long side of at most 4096. Keep that pass when the glyphs
    /// are large enough, or when the page is already one tile. Otherwise tile
    /// the original bitmap. `force=tile` skips the probe; `force=whole` keeps it.
    private static func recognizeAuto(
        decoded: DecodedImage,
        languages: [String],
        level: RecognitionLevel,
        script: ScriptMode,
        started: Date,
        minGlyphFrac: Double,
        force: TileForce?,
        scaleX: Double,
        scaleY: Double
    ) throws -> OCRPayload {
        let bitmapWidth = decoded.image.width
        let bitmapHeight = decoded.image.height
        if force == .tile {
            let rects = TilePlan.rects(width: bitmapWidth, height: bitmapHeight)
            let pass = try collect(
                rects: rects,
                bitmapWidth: bitmapWidth,
                bitmapHeight: bitmapHeight,
                languages: languages,
                level: level,
                image: decoded.image,
                scaleX: scaleX,
                scaleY: scaleY
            )
            let choice = TilePolicy.decide(
                width: decoded.originalWidth,
                height: decoded.originalHeight,
                lines: glyphBoxes(pass.lines),
                minGlyphFrac: minGlyphFrac,
                force: "tile"
            )
            return payload(
                decoded: decoded,
                scale: .auto,
                script: script,
                started: started,
                lines: pass.lines,
                frames: pass.frames,
                echo: pass.echo,
                tiles: rects.count,
                choice: choice
            )
        }
        let probe = try autoreleasepool { () -> Pass in
            let probeImage = downscaledProbe(decoded.image)
            let probeScaleX = Double(decoded.originalWidth) / Double(max(probeImage.width, 1))
            let probeScaleY = Double(decoded.originalHeight) / Double(max(probeImage.height, 1))
            let probeRect = TilePlan.Rect(x: 0, y: 0, width: probeImage.width, height: probeImage.height)
            return try collect(
                rects: [probeRect],
                bitmapWidth: probeImage.width,
                bitmapHeight: probeImage.height,
                languages: languages,
                level: level,
                image: probeImage,
                scaleX: probeScaleX,
                scaleY: probeScaleY
            )
        }
        let choice = TilePolicy.decide(
            width: decoded.originalWidth,
            height: decoded.originalHeight,
            lines: glyphBoxes(probe.lines),
            minGlyphFrac: minGlyphFrac,
            force: force == .whole ? "whole" : nil
        )
        if choice.mode == "whole" {
            return payload(
                decoded: decoded,
                scale: .auto,
                script: script,
                started: started,
                lines: probe.lines,
                frames: probe.frames,
                echo: probe.echo,
                tiles: 1,
                choice: choice
            )
        }
        let rects = TilePlan.rects(width: bitmapWidth, height: bitmapHeight)
        let tiled = try collect(
            rects: rects,
            bitmapWidth: bitmapWidth,
            bitmapHeight: bitmapHeight,
            languages: languages,
            level: level,
            image: decoded.image,
            scaleX: scaleX,
            scaleY: scaleY
        )
        return payload(
            decoded: decoded,
            scale: .auto,
            script: script,
            started: started,
            lines: tiled.lines,
            frames: tiled.frames,
            echo: tiled.echo,
            tiles: rects.count,
            choice: choice
        )
    }

    /// Vision's whole-image pass already shrinks by the long side. A probe
    /// above 4096 matches a native pass and costs more to decode.
    private static func downscaledProbe(_ image: CGImage) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > TilePolicy.probeMaxSide,
              let scaled = scaleDown(image, longEdge: TilePolicy.probeMaxSide) else {
            return image
        }
        return scaled
    }

    private static func glyphBoxes(_ lines: [OCRLine]) -> [GlyphBox] {
        lines.map { GlyphBox(text: $0.text, width: $0.bbox.width) }
    }

    private struct Pass {
        var lines: [OCRLine]
        var frames: [TileFrame?]
        var echo: RecognitionEcho
    }

    private static func collect(
        rects: [TilePlan.Rect],
        bitmapWidth: Int,
        bitmapHeight: Int,
        languages: [String],
        level: RecognitionLevel,
        image source: CGImage,
        scaleX: Double,
        scaleY: Double
    ) throws -> Pass {
        var collected: [OCRLine] = []
        var tileFrames: [TileFrame?] = []
        var echo = RecognitionEcho(languages: languages, revision: 0)
        for rect in rects {
            let frame = TileFrame(
                x: Double(rect.x) * scaleX,
                y: Double(rect.y) * scaleY,
                width: Double(rect.width) * scaleX,
                height: Double(rect.height) * scaleY
            )
            let piece = try autoreleasepool { () -> [OCRLine] in
                let image: CGImage
                let originX: Int
                let originY: Int
                if rect.x == 0, rect.y == 0, rect.width == bitmapWidth, rect.height == bitmapHeight {
                    image = source
                    originX = 0
                    originY = 0
                } else {
                    guard let cropped = cropBitmap(source, x: rect.x, y: rect.y, width: rect.width, height: rect.height) else {
                        throw OCREngineError.vision("could not crop tile")
                    }
                    image = cropped
                    originX = rect.x
                    originY = rect.y
                }
                let pass = try OCREngine.lines(image: image, languages: languages, level: level)
                echo = pass.echo
                return pass.lines.map {
                    mapLine($0, originX: Double(originX), originY: Double(originY), scaleX: scaleX, scaleY: scaleY)
                }
            }
            collected.append(contentsOf: piece)
            for _ in piece {
                tileFrames.append(frame)
            }
        }
        return Pass(lines: collected, frames: tileFrames, echo: echo)
    }

    private static func payload(
        decoded: DecodedImage,
        scale: ScaleMode,
        script: ScriptMode,
        started: Date,
        lines: [OCRLine],
        frames: [TileFrame?],
        echo: RecognitionEcho,
        tiles: Int,
        choice: TileChoice
    ) -> OCRPayload {
        // One tile has no seam to stitch. Skip dedupe and only group rows and columns.
        let page = tiles == 1
            ? LineMerge.group(lines)
            : LineMerge.assemble(lines, tiles: frames)
        let scripted = applyScript(page, script)
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
        return OCRPayload(
            text: scripted.text,
            width: decoded.originalWidth,
            height: decoded.originalHeight,
            scale: scale.rawValue,
            tiles: tiles,
            mode: choice.mode,
            glyphPx: choice.glyphPx,
            glyphFrac: choice.glyphFrac,
            tileDecision: choice.tileDecision,
            elapsedMs: elapsed,
            languages: echo.languages,
            revision: echo.revision,
            script: script.rawValue,
            layout: LayoutMode.rows.rawValue,
            lines: scripted.lines,
            rows: scripted.rows,
            blocks: scripted.blocks
        )
    }

    private static func mapLine(
        _ line: OCRLine,
        originX: Double,
        originY: Double,
        scaleX: Double,
        scaleY: Double
    ) -> OCRLine {
        OCRLine(
            text: line.text,
            confidence: line.confidence,
            bbox: BBox(
                x: round2((line.bbox.x + originX) * scaleX),
                y: round2((line.bbox.y + originY) * scaleY),
                width: round2(line.bbox.width * scaleX),
                height: round2(line.bbox.height * scaleY)
            ),
            quad: Quad(
                topLeft: mapPoint(line.quad.topLeft, originX, originY, scaleX, scaleY),
                topRight: mapPoint(line.quad.topRight, originX, originY, scaleX, scaleY),
                bottomRight: mapPoint(line.quad.bottomRight, originX, originY, scaleX, scaleY),
                bottomLeft: mapPoint(line.quad.bottomLeft, originX, originY, scaleX, scaleY)
            )
        )
    }

    private static func mapPoint(_ point: Point, _ originX: Double, _ originY: Double, _ scaleX: Double, _ scaleY: Double) -> Point {
        Point(
            x: round2((point.x + originX) * scaleX),
            y: round2((point.y + originY) * scaleY)
        )
    }
}
