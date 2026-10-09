import AppKit
import SuseCore

enum MonitorMenuMetric: String, CaseIterable {
    case cpu, memory, network, gpu, temperature, battery

    var title: String {
        switch self {
        case .cpu: "CPU 利用率"
        case .memory: "内存利用率"
        case .network: "网络速度"
        case .gpu: "GPU 利用率"
        case .temperature: "CPU 温度"
        case .battery: "电池电量"
        }
    }

    func values(in snapshot: SystemMetricsSnapshot) -> [Double?] {
        switch self {
        case .cpu: [snapshot.cpu]
        case .memory: [snapshot.memory.flatMap { $0.total > 0 ? Double($0.used) / Double($0.total) : nil }]
        case .network: [snapshot.network?.incoming, snapshot.network?.outgoing]
        case .gpu: [snapshot.gpu]
        case .temperature: [snapshot.cpuTemperature]
        case .battery: [snapshot.battery?.fraction]
        }
    }

    func text(_ values: [Double?]) -> String {
        switch self {
        case .cpu: "CPU " + SystemMetricFormat.percent(values[0])
        case .memory: "内存 " + SystemMetricFormat.percent(values[0])
        case .network: "↓" + compactRate(values[0]) + " ↑" + compactRate(values[1])
        case .gpu: "GPU " + SystemMetricFormat.percent(values[0])
        case .temperature: values[0].map { String(format: "%.0f°C", $0) } ?? "温度 —"
        case .battery: "电池 " + SystemMetricFormat.percent(values[0])
        }
    }

    var reservedText: String {
        switch self {
        case .cpu: "CPU 100%"
        case .memory: "内存 100%"
        case .network: "↓1024M ↑1024M"
        case .gpu: "GPU 100%"
        case .temperature: "温度 —"
        case .battery: "电池 100%"
        }
    }

    private func compactRate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B", "K", "M", "G", "T"]
        var value = bytes
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 || value >= 100 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}

@MainActor
struct MonitorMenuPresentation {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let text: String
    let width: CGFloat
    let tooltip: String

    init(metrics: [MonitorMenuMetric], latest: SystemMetricsSnapshot, samples: [SystemMetricsSnapshot], sampleCount: Int) {
        var sections: [String] = []
        var details: [String] = []
        for metric in metrics {
            let current = metric.values(in: latest)
            let statistics = current.indices.map { index in
                SystemSampleStatistics(values: samples.suffix(sampleCount).map { metric.values(in: $0)[index] })
            }
            // A failed current reading stays unavailable, rather than displaying stale history.
            let displayed = current.indices.map { index -> Double? in
                guard let value = current[index], value.isFinite else { return nil }
                return sampleCount == 1 ? value : statistics[index]?.median ?? value
            }
            sections.append(metric.text(displayed))
            var detail = metric.title + "：" + metric.text(current)
            for (index, stats) in statistics.enumerated() {
                guard let stats else { continue }
                let format: (Double) -> String = metric == .network ? SystemMetricFormat.rate :
                    metric == .temperature ? { String(format: "%.0f°C", $0) } : { SystemMetricFormat.percent($0) }
                let direction = metric == .network ? (index == 0 ? "下载" : "上传") : ""
                detail += "\n\(direction)最近 \(stats.totalCount) 次 · 有效 \(stats.validCount) 次 · 中位数 \(format(stats.median)) · 范围 \(format(stats.minimum))–\(format(stats.maximum))"
            }
            if metric == .network { detail += "\n菜单栏单位：B/s，K = KiB/s，M = MiB/s，G = GiB/s，T = TiB/s" }
            details.append(detail)
        }
        text = sections.joined(separator: " · ")
        let reserved = metrics.map(\.reservedText).joined(separator: " · ")
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        width = ceil(max((text as NSString).size(withAttributes: attributes).width,
                         (reserved as NSString).size(withAttributes: attributes).width)) + 12
        tooltip = (["\(AppIdentity.name) · 系统监控 · 点击展开",
                    sampleCount == 1 ? "菜单栏显示实时读数" : "菜单栏显示最近最多 \(sampleCount) 次采样的中位数；面板显示实时读数"] + details).joined(separator: "\n")
    }
}
