import AppKit
import SuseCore

@MainActor
final class MonitorHistoryChart: NSView {
    struct Line {
        let series: MonitorSeries
        let title: String
        let color: NSColor
        let points: [MonitorHistoryPoint]
    }
    var lines: [Line] = [] { didSet { needsDisplay = true } }
    var timeRange = DateInterval(start: Date().addingTimeInterval(-900), duration: 900) { didSet { needsDisplay = true } }
    var ceiling = 1.0 { didSet { needsDisplay = true } }
    var unit = "%"
    var pulse = false { didSet { needsDisplay = true } }
    var compact = false
    var selectedTime: Date? { didSet { needsDisplay = true } }
    var hoverTime: Date? { didSet { needsDisplay = true } }
    var onHover: ((Date?) -> Void)?
    var onSelect: ((Date) -> Void)?
    var onZoom: ((DateInterval) -> Void)?
    var onPan: ((TimeInterval) -> Void)?
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var dragPans = false
    private var previousLines: [Line] = []
    private var animationTimer: Timer?
    private var animationStart: TimeInterval = 0
    private var progress = 1.0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var plot: CGRect { bounds.insetBy(dx: compact ? 3 : 52, dy: compact ? 5 : 30) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("系统指标历史图表")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    isolated deinit { animationTimer?.invalidate() }

    func update(lines newLines: [Line], animated: Bool) {
        animationTimer?.invalidate()
        previousLines = lines
        lines = newLines
        progress = 1
        guard animated, !compact, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              previousLines.map(\.series) == newLines.map(\.series) else { return }
        progress = 0
        animationStart = ProcessInfo.processInfo.systemUptime
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.window?.isVisible == true else { self.stopAnimation(); return }
                self.progress = min(1, (ProcessInfo.processInfo.systemUptime - self.animationStart) / 0.28)
                self.needsDisplay = true
                if self.progress >= 1 { self.stopAnimation() }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        progress = 1
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopAnimation() } }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }

    func time(at x: CGFloat) -> Date {
        timeRange.start.addingTimeInterval(Double(min(1, max(0, (x - plot.minX) / max(1, plot.width)))) * timeRange.duration)
    }
    private func x(_ time: Date) -> CGFloat { plot.minX + CGFloat(time.timeIntervalSince(timeRange.start) / max(1, timeRange.duration)) * plot.width }
    private func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(min(1, max(0, value / max(0.0001, ceiling)))) * plot.height }

    override func mouseMoved(with event: NSEvent) {
        guard !compact else { return }
        let location = convert(event.locationInWindow, from: nil)
        onHover?(plot.contains(location) ? time(at: location.x) : nil)
    }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        guard !compact else { return }
        let position = convert(event.locationInWindow, from: nil)
        guard plot.contains(position) else { return }
        window?.makeFirstResponder(self)
        dragStart = position
        dragEnd = position
        dragPans = event.modifierFlags.contains(.option)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; dragEnd = nil; needsDisplay = true }
        if abs(end.x - start.x) < 5 {
            let target = time(at: end.x)
            let valid = lines.flatMap(\.points).filter { $0.value != nil }
            if let point = valid.min(by: { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }) {
                if abs(x(point.time) - end.x) <= 10 { onSelect?(point.peakTime ?? point.time) }
            }
        } else if dragPans {
            onPan?(time(at: start.x).timeIntervalSince(time(at: end.x)))
        } else {
            let a = time(at: min(start.x, end.x)), b = time(at: max(start.x, end.x))
            if b.timeIntervalSince(a) >= 5 { onZoom?(DateInterval(start: a, end: b)) }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            onPan?(Double(event.scrollingDeltaX + event.scrollingDeltaY) / max(1, Double(plot.width)) * timeRange.duration)
        } else if event.modifierFlags.contains(.command) {
            let factor = event.scrollingDeltaY > 0 ? 0.8 : 1.25
            let duration = min(MonitorHistory.retention, max(5, timeRange.duration * factor))
            onZoom?(DateInterval(start: timeRange.end.addingTimeInterval(-duration), duration: duration))
        } else { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onPan?(-timeRange.duration / 10) }
        else if event.keyCode == 124 { onPan?(timeRange.duration / 10) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard plot.width > 0, plot.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        if !compact {
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let lineY = y(ceiling * fraction)
                NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
                let line = NSBezierPath(); line.move(to: CGPoint(x: plot.minX, y: lineY)); line.line(to: CGPoint(x: plot.maxX, y: lineY)); line.lineWidth = 0.5; line.stroke()
                text(format(ceiling * fraction), at: CGPoint(x: 2, y: lineY - 7))
            }
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            for fraction in [0.0, 0.5, 1.0] {
                let time = timeRange.start.addingTimeInterval(timeRange.duration * fraction)
                let label = formatter.string(from: time)
                text(label, at: CGPoint(x: plot.minX + CGFloat(fraction) * plot.width - (fraction == 1 ? 34 : 0), y: plot.maxY + 8))
            }
            text(unit, at: CGPoint(x: plot.minX, y: 2))
        }
        context.saveGState()
        context.clip(to: plot.insetBy(dx: -1, dy: -2))
        for (index, line) in lines.enumerated() {
            var segments: [[CGPoint]] = []
            var segment: [CGPoint] = []
            for (pointIndex, point) in line.points.enumerated() {
                guard let value = point.value else { if !segment.isEmpty { segments.append(segment); segment = [] }; continue }
                var shown = value
                if progress < 1, previousLines.indices.contains(index), previousLines[index].points.indices.contains(pointIndex),
                   let old = previousLines[index].points[pointIndex].value {
                    let t = progress * progress * (3 - 2 * progress)
                    shown = old + (value - old) * t
                }
                let position = CGPoint(x: x(point.time), y: y(shown))
                segment.append(position)
                if let minimum = point.minimum, let maximum = point.maximum, maximum > minimum {
                    context.setStrokeColor(line.color.withAlphaComponent(0.16).cgColor)
                    context.setLineWidth(max(1, plot.width / CGFloat(max(1, line.points.count)) * 0.6))
                    context.move(to: CGPoint(x: position.x, y: y(minimum))); context.addLine(to: CGPoint(x: position.x, y: y(maximum))); context.strokePath()
                }
                if pulse {
                    context.setStrokeColor(line.color.withAlphaComponent(0.22).cgColor)
                    context.setLineWidth(2)
                    context.move(to: CGPoint(x: position.x, y: plot.maxY)); context.addLine(to: position); context.strokePath()
                }
            }
            if !segment.isEmpty { segments.append(segment) }
            for segment in segments {
                let path = MonitorPlotGeometry.path(segment)
                if let first = segment.first, let last = segment.last {
                    let area = path.mutableCopy()!
                    area.addLine(to: CGPoint(x: last.x, y: plot.maxY)); area.addLine(to: CGPoint(x: first.x, y: plot.maxY)); area.closeSubpath()
                    context.saveGState(); context.addPath(area); context.clip()
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                 colors: [line.color.withAlphaComponent(0.23).cgColor, line.color.withAlphaComponent(0).cgColor] as CFArray,
                                                 locations: [0, 1]) {
                        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
                    }
                    context.restoreGState()
                }
                if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                    context.saveGState(); context.setShadow(offset: .zero, blur: compact ? 0 : 5, color: line.color.withAlphaComponent(0.4).cgColor)
                    context.setStrokeColor(line.color.withAlphaComponent(0.2).cgColor); context.setLineWidth(4); context.addPath(path); context.strokePath(); context.restoreGState()
                }
                context.setStrokeColor(line.color.cgColor); context.setLineWidth(compact ? 1.5 : 2); context.setLineCap(.round)
                if index > 0 { context.setLineDash(phase: 0, lengths: [5, 3]) }
                else { context.setLineDash(phase: 0, lengths: []) }
                context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            }
            if let last = line.points.last, let value = last.value {
                let point = CGPoint(x: x(last.time), y: y(value))
                context.setFillColor(line.color.withAlphaComponent(0.15).cgColor); context.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
                context.setFillColor(line.color.cgColor); context.fillEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            }
        }
        if let time = hoverTime ?? selectedTime, timeRange.contains(time) {
            let position = x(time)
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor); context.setLineWidth(0.5)
            context.move(to: CGPoint(x: position, y: plot.minY)); context.addLine(to: CGPoint(x: position, y: plot.maxY)); context.strokePath()
            for line in lines {
                let peak = selectedTime == time ? line.points.first { $0.peakTime.map { abs($0.timeIntervalSince(time)) < 0.05 } == true }?.maximum : nil
                if let value = peak ?? MonitorPlotGeometry.value(at: time, points: line.points) {
                    context.setFillColor(line.color.cgColor); context.fillEllipse(in: CGRect(x: position - 3.5, y: y(value) - 3.5, width: 7, height: 7))
                }
            }
        }
        if let a = dragStart, let b = dragEnd, !dragPans {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(CGRect(x: min(a.x, b.x), y: plot.minY, width: abs(a.x - b.x), height: plot.height))
        }
        context.restoreGState()
        if let time = hoverTime, timeRange.contains(time), !compact {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
            var rows = [formatter.string(from: time)]
            rows += lines.map { line in
                let value = MonitorPlotGeometry.value(at: time, points: line.points)
                let reading = value.map { unit == "%" ? String(format: "%.0f%%", $0 * 100) : String(format: "%.1f %@", $0, unit) } ?? "—"
                return "\(line.title)  \(reading)"
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
            let label = rows.joined(separator: "\n") as NSString
            let size = label.size(withAttributes: attributes)
            let rect = CGRect(x: min(plot.maxX - size.width - 24, max(plot.minX, x(time) + 14)), y: plot.minY + 8, width: size.width + 24, height: size.height + 18)
            let bubble = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.controlBackgroundColor.setFill(); bubble.fill()
            NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); bubble.lineWidth = 0.5; bubble.stroke()
            label.draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 9), withAttributes: attributes)
        }
    }

    private func format(_ value: Double) -> String {
        unit == "%" ? String(format: "%.0f", value * 100) : String(format: value >= 100 ? "%.0f" : "%.1f", value)
    }
    private func text(_ value: String, at point: CGPoint) {
        (value as NSString).draw(at: point, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
