import SwiftUI

/// 可用空间趋势折线图 + 清理事件柱状图（橙色=手动，绿色=自动）
struct SpaceChartView: View {
    let history: [(Date, Int64)]
    let waterline: Int64
    let events: [(timestamp: Date, freedBytes: Int64, isManual: Bool)]

    private var maxValue: Int64 {
        let maxV = max(history.map { $0.1 }.max() ?? 0, 1)
        return ((maxV + 9_999_999_999) / 10_000_000_000) * 10_000_000_000
    }
    private var minValue: Int64 { 0 }

    private var earliest: Date {
        min(
            history.first?.0 ?? .distantPast,
            events.map(\.timestamp).min() ?? history.first?.0 ?? .distantPast
        )
    }

    private var latest: Date {
        max(
            history.last?.0 ?? .distantPast,
            events.map(\.timestamp).max() ?? history.last?.0 ?? .distantPast
        )
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let left: CGFloat = 40
            let right: CGFloat = 6
            let top: CGFloat = 6
            let bottom: CGFloat = 16
            let plotW = max(w - left - right, 1)
            let plotH = max(h - top - bottom, 1)
            let range = max(maxValue - minValue, 1)
            let timeSpan = max(latest.timeIntervalSince(earliest), 1)

            let yValue: (Int64) -> CGFloat = { v in
                top + plotH - plotH * CGFloat(Double(v - minValue) / Double(range))
            }
            let xValue: (Date) -> CGFloat = { t in
                left + plotW * CGFloat(t.timeIntervalSince(earliest) / timeSpan)
            }

            ZStack {
                // 坐标轴（Y 轴在左，X 轴在底）
                Path { path in
                    path.move(to: CGPoint(x: left, y: top))
                    path.addLine(to: CGPoint(x: left, y: top + plotH))
                    path.move(to: CGPoint(x: left, y: top + plotH))
                    path.addLine(to: CGPoint(x: left + plotW, y: top + plotH))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)

                // 水线参考线（仅绘图区内，超出范围时贴边）
                Rectangle()
                    .fill(Color.orange.opacity(0.6))
                    .frame(width: plotW, height: 1)
                    .position(
                        x: left + plotW / 2,
                        y: min(max(yValue(waterline), top), top + plotH)
                    )

                // 清理事件柱
                let maxEvent = max(events.map(\.freedBytes).max() ?? 0, 1)
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    let ex = xValue(event.timestamp)
                    let barHeight = plotH * 0.5 * CGFloat(Double(event.freedBytes) / Double(maxEvent))
                    Rectangle()
                        .fill((event.isManual ? Color.orange : Color.green).opacity(0.7))
                        .frame(width: 6, height: max(barHeight, 2))
                        .position(x: ex, y: top + plotH - barHeight / 2)
                }

                // 可用空间折线
                Path { path in
                    for (index, point) in history.enumerated() {
                        let px = index == history.count - 1 ? left + plotW : xValue(point.0)
                        let py = yValue(point.1)
                        if index == 0 {
                            path.move(to: CGPoint(x: px, y: py))
                        } else {
                            path.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                // 当前点
                if let lastPoint = history.last {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .position(x: left + plotW, y: yValue(lastPoint.1))
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .overlay(alignment: .topLeading) {
            Text(verbatim: "\(Int(maxValue / 1_000_000_000))GB")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: "0GB")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .overlay(alignment: .bottomLeading) {
            Text(shortDate(earliest))
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .padding(.leading, 42)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(shortDate(latest))
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
