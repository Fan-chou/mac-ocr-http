import CoreGraphics
import ImageIO
import LineMergeCore

enum Geometry {
    /// EXIF orientations 5...8 swap the stored pixel axes. Vision's normalized
    /// boxes are in the oriented image, so pixel conversion must use this size
    /// when the CGImage itself has not already been rotated upright.
    static func orientedSize(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: CGImagePropertyOrientation
    ) -> (width: Int, height: Int) {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return (pixelHeight, pixelWidth)
        default:
            return (pixelWidth, pixelHeight)
        }
    }

    /// Vision `boundingBox` is normalized with a bottom-left origin.
    /// `y_top = (1 - origin.y - height) * pixelHeight`.
    /// A full-image Vision rect (origin 0,0 size 1,1) becomes pixel (0,0,width,height).
    static func pixelBBox(normalizedBottomLeft rect: CGRect, width: Int, height: Int) -> BBox {
        let pixelWidth = Double(width)
        let pixelHeight = Double(height)
        return BBox(
            x: round2(Double(rect.origin.x) * pixelWidth),
            y: round2((1.0 - Double(rect.origin.y) - Double(rect.size.height)) * pixelHeight),
            width: round2(Double(rect.size.width) * pixelWidth),
            height: round2(Double(rect.size.height) * pixelHeight)
        )
    }

    /// Vision points are normalized with a bottom-left origin. Pixel Y grows downward.
    static func pixelPoint(normalizedBottomLeft point: CGPoint, width: Int, height: Int) -> Point {
        Point(
            x: round2(Double(point.x) * Double(width)),
            y: round2((1.0 - Double(point.y)) * Double(height))
        )
    }
}

func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}
