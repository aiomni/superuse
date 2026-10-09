import CoreGraphics

public enum AnnotationGeometry {
    public static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }

    public static func distance(from point: CGPoint, to start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength))
        return hypot(point.x - start.x - fraction * dx, point.y - start.y - fraction * dy)
    }

    public static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// Keep the opposite corner fixed, with a minimum size instead of flipping the object.
    public static func resizing(_ rect: CGRect, corner: Int, to point: CGPoint, minimum: CGFloat) -> CGRect {
        let opposite = corners(of: rect)[(corner + 2) % 4]
        let left = corner == 0 || corner == 3
        let top = corner == 0 || corner == 1
        let x = left ? min(point.x, opposite.x - minimum) : max(point.x, opposite.x + minimum)
        let y = top ? min(point.y, opposite.y - minimum) : max(point.y, opposite.y + minimum)
        return bounds(of: [opposite, CGPoint(x: x, y: y)])
    }

    public static func mapping(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        points.map { point in
            CGPoint(x: new.minX + (old.width > 0 ? (point.x - old.minX) / old.width * new.width : 0),
                    y: new.minY + (old.height > 0 ? (point.y - old.minY) / old.height * new.height : 0))
        }
    }

    /// Change the wrapping width while keeping the opposite horizontal edge fixed.
    public static func resizingWidth(_ rect: CGRect, fromLeft: Bool, to x: CGFloat, minimum: CGFloat) -> CGRect {
        if fromLeft {
            let left = min(x, rect.maxX - minimum)
            return CGRect(x: left, y: rect.minY, width: rect.maxX - left, height: rect.height)
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(minimum, x - rect.minX), height: rect.height)
    }

    public static func clampedTranslation(_ delta: CGPoint, bounds: CGRect, within size: CGSize) -> CGPoint {
        CGPoint(x: min(max(delta.x, -bounds.minX), max(0, size.width - bounds.maxX)),
                y: min(max(delta.y, -bounds.minY), max(0, size.height - bounds.maxY)))
    }
}
