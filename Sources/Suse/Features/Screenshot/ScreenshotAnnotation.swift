import AppKit
import SuseCore

enum AnnotationTool: Int, CaseIterable {
    case select, pen, arrow, rectangle, ellipse, text, emoji, redact, mosaic
    var title: String { ["选择", "画笔", "箭头", "矩形", "椭圆", "文字", "表情", "遮挡", "打码"][rawValue] }
    var symbol: String {
        ["cursorarrow", "pencil.tip", "arrow.up.right", "rectangle", "oval", "textformat", "face.smiling",
         "rectangle.fill", "checkerboard.rectangle"][rawValue]
    }
    var tooltip: String {
        switch self {
        case .select: "选择：单击标注后拖动位置或控制点，调整颜色、粗细；双击文字编辑，Delete 删除"
        case .text: "文字：单击输入，双击继续编辑；拖动左右中点调整换行宽度，角点缩放字号；⌘↩ 结束输入"
        case .emoji: "表情：单击画布，从系统表情选择器插入 emoji"
        case .redact: "遮挡：拖动框选，用不透明黑色覆盖"
        case .mosaic: "打码：拖动框选马赛克区域，细／中／粗调整颗粒大小"
        default: title
        }
    }
}

@MainActor
struct ScreenshotAnnotation {
    let id = UUID()
    let tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var textWidth: CGFloat = 320
    var mosaicTiles: CGImage?

    var fontSize: CGFloat { max(8, width * 5 + 12) }
    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
    }
    var attributedText: NSAttributedString { NSAttributedString(string: text, attributes: textAttributes) }
    private var measuredText: CGRect {
        attributedText.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    var textLayoutBounds: CGRect {
        CGRect(origin: points[0], size: CGSize(width: textWidth, height: max(fontSize * 1.3, ceil(measuredText.height))))
    }
    var bounds: CGRect {
        guard tool == .text else { return AnnotationGeometry.bounds(of: points) }
        return CGRect(origin: points[0], size: CGSize(width: max(1, ceil(measuredText.width)), height: textLayoutBounds.height))
    }
    var selectionBounds: CGRect { tool == .text ? textLayoutBounds : bounds }
    var handles: [CGPoint] {
        if tool == .arrow { return [points[0], points[points.count - 1]] }
        let corners = AnnotationGeometry.corners(of: selectionBounds)
        guard tool == .text else { return corners }
        return corners + [CGPoint(x: textLayoutBounds.minX, y: textLayoutBounds.midY),
                          CGPoint(x: textLayoutBounds.maxX, y: textLayoutBounds.midY)]
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .pen, .arrow:
            let path = points + (tool == .arrow ? arrowhead : [])
            if path.count == 1 { return hypot(point.x - path[0].x, point.y - path[0].y) <= tolerance + width / 2 }
            return zip(path, path.dropFirst()).contains {
                AnnotationGeometry.distance(from: point, to: $0.0, end: $0.1) <= tolerance + width / 2
            }
        case .ellipse:
            let expanded = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard expanded.width > 0, expanded.height > 0 else { return false }
            return pow((point.x - expanded.midX) / (expanded.width / 2), 2)
                + pow((point.y - expanded.midY) / (expanded.height / 2), 2) <= 1
        default: return selectionBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    var arrowhead: [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        let angle = atan2(last.y - first.y, last.x - first.x)
        let length = min(width * 4, hypot(last.x - first.x, last.y - first.y) / 2)
        let ends = [-CGFloat.pi / 6, CGFloat.pi / 6].map { delta in
            CGPoint(x: last.x - length * cos(angle + delta), y: last.y - length * sin(angle + delta))
        }
        return [ends[0], last, ends[1]]
    }
}
