import Foundation

public struct Point: Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BBox: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct Quad: Codable, Sendable {
    public var topLeft: Point
    public var topRight: Point
    public var bottomRight: Point
    public var bottomLeft: Point

    public init(topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

public struct OCRLine: Codable, Sendable {
    public var text: String
    public var confidence: Double
    public var bbox: BBox
    public var quad: Quad

    public init(text: String, confidence: Double, bbox: BBox, quad: Quad) {
        self.text = text
        self.confidence = confidence
        self.bbox = bbox
        self.quad = quad
    }
}

/// One column block, or one document paragraph when `layout=document`.
/// `rowIndices` index into `rows`.
public struct OCRBlock: Codable, Sendable {
    public var bbox: BBox
    public var rowIndices: [Int]

    public init(bbox: BBox, rowIndices: [Int]) {
        self.bbox = bbox
        self.rowIndices = rowIndices
    }
}

public struct OCRRow: Codable, Sendable {
    public var text: String
    public var bbox: BBox
    public var confidence: Double
    /// Indexes into the response `lines` array, left to right.
    public var lineIndices: [Int]

    public init(text: String, bbox: BBox, confidence: Double, lineIndices: [Int]) {
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
        self.lineIndices = lineIndices
    }
}

/// Axis-aligned tile rectangle in the same pixel space as `OCRLine.bbox`.
public struct TileFrame: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
}
