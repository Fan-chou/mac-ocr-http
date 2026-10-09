import CoreGraphics
import Foundation
import ImageIO

struct DecodedImage {
    let image: CGImage
    /// `.up` when ImageIO already baked EXIF orientation into `image`.
    let orientation: CGImagePropertyOrientation
    /// Pixel size of `image`, the upright bitmap Vision sees.
    let width: Int
    let height: Int
    /// Oriented source size. Response boxes are in this space.
    let originalWidth: Int
    let originalHeight: Int
}

/// Decode in memory. `longEdge == nil` keeps the original resolution (EXIF
/// applied, no shrink). A non-nil `longEdge` is the downscale path only.
/// Pixel count is taken from image properties before the bitmap is created.
func decodeImage(_ data: Data, maxPixels: Int, longEdge: Int?) throws -> DecodedImage {
    guard !data.isEmpty else { throw ImageDecodeError.unrecognized }
    let noCache: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache as CFDictionary) else {
        throw ImageDecodeError.unrecognized
    }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    let rawWidth = intProp(props, kCGImagePropertyPixelWidth)
    let rawHeight = intProp(props, kCGImagePropertyPixelHeight)
    let orientation = exifOrientation(props)
    let oriented = Geometry.orientedSize(
        pixelWidth: rawWidth,
        pixelHeight: rawHeight,
        orientation: orientation
    )
    guard rawWidth > 0, rawHeight > 0, oriented.width > 0, oriented.height > 0 else {
        throw ImageDecodeError.unrecognized
    }
    let pixels = Int64(oriented.width) * Int64(oriented.height)
    if pixels > Int64(max(1, maxPixels)) {
        throw ImageDecodeError.tooLarge(
            width: oriented.width,
            height: oriented.height,
            maxPixels: maxPixels
        )
    }

    let fullEdge = max(oriented.width, oriented.height)
    let thumbLimit = longEdge ?? fullEdge
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: thumbLimit,
        kCGImageSourceShouldCache: false,
    ]
    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
       image.width > 0, image.height > 0,
       let owned = ownedBitmap(image) {
        let bitmap = try fittedBitmap(owned, longEdge: longEdge, fullEdge: fullEdge, orientation: orientation, source: source, noCache: noCache)
        return DecodedImage(
            image: bitmap,
            orientation: .up,
            width: bitmap.width,
            height: bitmap.height,
            originalWidth: oriented.width,
            originalHeight: oriented.height
        )
    }

    guard orientation == .up,
          let raw = CGImageSourceCreateImageAtIndex(source, 0, noCache as CFDictionary),
          raw.width > 0, raw.height > 0,
          let owned = ownedBitmap(raw) else {
        throw ImageDecodeError.unrecognized
    }
    let bitmap = try fittedBitmap(owned, longEdge: longEdge, fullEdge: fullEdge, orientation: .up, source: source, noCache: noCache)
    return DecodedImage(
        image: bitmap,
        orientation: .up,
        width: bitmap.width,
        height: bitmap.height,
        originalWidth: oriented.width,
        originalHeight: oriented.height
    )
}

/// Copy one tile into its own buffer so the crop does not keep a second view of the full image.
func cropBitmap(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let clipped = rect.intersection(bounds)
    guard clipped.width >= 1, clipped.height >= 1,
          let cropped = image.cropping(to: clipped) else { return nil }
    return ownedBitmap(cropped)
}

private func fittedBitmap(
    _ owned: CGImage,
    longEdge: Int?,
    fullEdge: Int,
    orientation: CGImagePropertyOrientation,
    source: CGImageSource,
    noCache: [CFString: Any]
) throws -> CGImage {
    var bitmap = owned
    if let longEdge, max(bitmap.width, bitmap.height) > longEdge {
        guard let scaled = scaleDown(bitmap, longEdge: longEdge) else {
            throw ImageDecodeError.unrecognized
        }
        bitmap = scaled
    }
    if longEdge == nil && max(bitmap.width, bitmap.height) + 1 < fullEdge {
        if orientation == .up,
           let raw = CGImageSourceCreateImageAtIndex(source, 0, noCache as CFDictionary),
           raw.width > 0, raw.height > 0,
           let full = ownedBitmap(raw),
           max(full.width, full.height) + 1 >= fullEdge {
            return full
        }
        throw ImageDecodeError.unrecognized
    }
    return bitmap
}

func scaleDown(_ image: CGImage, longEdge: Int) -> CGImage? {
    let width = image.width
    let height = image.height
    let long = max(width, height)
    guard long > longEdge, long > 0 else { return image }
    let scale = Double(longEdge) / Double(long)
    let targetWidth = max(1, Int((Double(width) * scale).rounded()))
    let targetHeight = max(1, Int((Double(height) * scale).rounded()))
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: alpha
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
}

/// Copy pixels into a context-owned buffer so the image does not keep the
/// source, its cache, or the compressed request bytes alive.
func ownedBitmap(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: alpha
    ) else { return nil }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private func intProp(_ props: NSDictionary?, _ key: CFString) -> Int {
    guard let value = props?[key] else { return 0 }
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Int { return number }
    return 0
}

private func exifOrientation(_ props: NSDictionary?) -> CGImagePropertyOrientation {
    guard let value = props?[kCGImagePropertyOrientation] else { return .up }
    let raw: UInt32
    if let number = value as? NSNumber {
        raw = number.uint32Value
    } else if let number = value as? UInt32 {
        raw = number
    } else {
        return .up
    }
    return CGImagePropertyOrientation(rawValue: raw) ?? .up
}
