import Foundation
import CoreGraphics

/// Shape-preserving cubic interpolation: no visual overshoot above real samples.
public enum MonitorPlotGeometry {
    /// Matches the plotted monotone cubic and refuses to interpolate across missing data.
    public static func value(at time: Date, points: [MonitorHistoryPoint]) -> Double? {
        guard let first = points.first, let last = points.last, time >= first.time, time <= last.time else { return nil }
        if let exact = points.first(where: { $0.time == time }) { return exact.value }
        guard let right = points.firstIndex(where: { $0.time > time }), right > 0,
              let a = points[right - 1].value, let b = points[right].value else { return nil }
        let width = points[right].time.timeIntervalSince(points[right - 1].time)
        guard width > 0 else { return nil }
        let slope = (b - a) / width
        func tangent(_ adjacent: Double?) -> Double {
            guard let adjacent else { return slope }
            return adjacent * slope <= 0 ? 0 : 2 * adjacent * slope / (adjacent + slope)
        }
        var preceding: Double?, following: Double?
        if right > 1, let value = points[right - 2].value {
            let distance = points[right - 1].time.timeIntervalSince(points[right - 2].time)
            if distance > 0 { preceding = (a - value) / distance }
        }
        if right + 1 < points.count, let value = points[right + 1].value {
            let distance = points[right + 1].time.timeIntervalSince(points[right].time)
            if distance > 0 { following = (value - b) / distance }
        }
        let t = time.timeIntervalSince(points[right - 1].time) / width, u = 1 - t
        return u * u * u * a + 3 * u * u * t * (a + width / 3 * tangent(preceding))
            + 3 * u * t * t * (b - width / 3 * tangent(following)) + t * t * t * b
    }

    public static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let slopes = zip(points, points.dropFirst()).map { a, b in
            b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0
        }
        var tangents = [slopes[0]]
        for index in 1..<points.count - 1 {
            let a = slopes[index - 1], b = slopes[index]
            tangents.append(a * b <= 0 ? 0 : 2 * a * b / (a + b))
        }
        tangents.append(slopes.last!)
        for index in slopes.indices {
            let a = points[index], b = points[index + 1], dx = (b.x - a.x) / 3
            if dx <= 0 { path.addLine(to: b); continue }
            path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y + dx * tangents[index]),
                          control2: CGPoint(x: b.x - dx, y: b.y - dx * tangents[index + 1]))
        }
        return path
    }
}
