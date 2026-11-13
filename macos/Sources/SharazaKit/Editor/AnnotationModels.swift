import AppKit
import CoreGraphics
import Foundation

public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case select = "Select"
    case arrow = "Arrow"
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case line = "Line"
    case freehand = "Pen"
    case highlight = "Highlight"
    case text = "Text"
    case speechBalloon = "Callout"
    case stepNumber = "Step #"
    case magnify = "Magnify"
    case smartEraser = "Smart Erase"
    case blur = "Blur"
    case pixelate = "Pixelate"
    case spotlight = "Spotlight"
    case crop = "Crop"

    public var id: String { rawValue }

    public var systemSymbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .freehand: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .speechBalloon: return "bubble.left.fill"
        case .stepNumber: return "1.circle.fill"
        case .magnify: return "plus.magnifyingglass"
        case .smartEraser: return "eraser.fill"
        case .blur: return "drop.fill"
        case .pixelate: return "square.grid.3x3.fill"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }
}

public struct RGBAColor: Equatable, Sendable {
    public var r: CGFloat
    public var g: CGFloat
    public var b: CGFloat
    public var a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let red = RGBAColor(r: 0.95, g: 0.22, b: 0.26)
    public static let orange = RGBAColor(r: 0.98, g: 0.55, b: 0.12)
    public static let yellow = RGBAColor(r: 0.98, g: 0.84, b: 0.15)
    public static let green = RGBAColor(r: 0.18, g: 0.80, b: 0.44)
    public static let blue = RGBAColor(r: 0.16, g: 0.52, b: 0.98)
    public static let purple = RGBAColor(r: 0.62, g: 0.32, b: 0.95)
    public static let white = RGBAColor(r: 1.0, g: 1.0, b: 1.0)
    public static let black = RGBAColor(r: 0.08, g: 0.08, b: 0.10)

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Normalized/image-pixel space annotation item (coordinates in CGImage pixel space with top-left origin).
public struct AnnotationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tool: EditorTool
    public var startPoint: CGPoint
    public var endPoint: CGPoint
    public var freehandPoints: [CGPoint]
    public var color: RGBAColor
    public var strokeWidth: CGFloat
    public var filled: Bool
    public var text: String
    public var fontSize: CGFloat
    public var stepValue: Int
    public var effectIntensity: CGFloat

    public init(
        id: UUID = UUID(),
        tool: EditorTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        freehandPoints: [CGPoint] = [],
        color: RGBAColor = .red,
        strokeWidth: CGFloat = 4.0,
        filled: Bool = false,
        text: String = "",
        fontSize: CGFloat = 24.0,
        stepValue: Int = 1,
        effectIntensity: CGFloat = 14.0
    ) {
        self.id = id
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.freehandPoints = freehandPoints
        self.color = color
        self.strokeWidth = strokeWidth
        self.filled = filled
        self.text = text
        self.fontSize = fontSize
        self.stepValue = stepValue
        self.effectIntensity = effectIntensity
    }

    public var boundingRect: CGRect {
        if tool == .freehand, let first = freehandPoints.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in freehandPoints {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
        if tool == .stepNumber {
            let r = max(16, fontSize * 0.85)
            return CGRect(x: startPoint.x - r, y: startPoint.y - r, width: r * 2, height: r * 2)
        }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        startPoint.x += dx
        startPoint.y += dy
        endPoint.x += dx
        endPoint.y += dy
        for i in freehandPoints.indices {
            freehandPoints[i].x += dx
            freehandPoints[i].y += dy
        }
    }
}
