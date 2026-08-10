import SwiftUI

struct PoolTankView: View {
    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let topInflows: [(name: String, bytes: Int64)]
    let weeklyCleanedBytes: Int64

    private var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - availableBytes) / Double(totalBytes) : 0
    }

    private var waterlineFraction: Double {
        totalBytes > 0 ? Double(totalBytes - waterlineBytes) / Double(totalBytes) : 0
    }

    private var belowWaterline: Bool {
        availableBytes < waterlineBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            inlets
            tankCanvas
            outlets
        }
    }

    private var inlets: some View {
        HStack(spacing: 8) {
            ForEach(Array(topInflows.prefix(2).enumerated()), id: \.offset) { _, inflow in
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("\(inflow.name) +\(Format.bytes(inflow.bytes))")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
            if topInflows.isEmpty {
                Text("本周暂无显著增长来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var outlets: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.green)
            Text("出水（清理）\(Format.bytes(weeklyCleanedBytes))/周")
            Spacer()
        }
        .font(.caption)
    }

    private var tankCanvas: some View {
        Canvas { context, size in
            let tankRect = CGRect(
                x: 48,
                y: 6,
                width: size.width - 48 - 8,
                height: size.height - 12
            )
            let tankPath = Path(roundedRect: tankRect, cornerRadius: 10)

            // 池体背景（空气 = 可用空间）
            context.fill(tankPath, with: .color(Color.secondary.opacity(0.06)))

            // 水（已用空间），从底部向上
            let waterHeight = tankRect.height * CGFloat(min(max(usedFraction, 0), 1))
            let waterRect = CGRect(
                x: tankRect.minX,
                y: tankRect.maxY - waterHeight,
                width: tankRect.width,
                height: waterHeight
            )
            if waterHeight > 0 {
                context.clip(to: tankPath)
                context.fill(Path(waterRect), with: .linearGradient(
                    Gradient(colors: [waterColor.opacity(0.55), waterColor.opacity(0.9)]),
                    startPoint: CGPoint(x: 0, y: tankRect.maxY),
                    endPoint: CGPoint(x: 0, y: tankRect.minY)
                ))
                // 水面高光线
                var surface = Path()
                surface.move(to: CGPoint(x: tankRect.minX + 2, y: waterRect.minY))
                surface.addLine(to: CGPoint(x: tankRect.maxX - 2, y: waterRect.minY))
                context.stroke(surface, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }

            // 目标水线（虚线）
            let waterlineY = tankRect.maxY - tankRect.height * CGFloat(waterlineFraction)
            var waterline = Path()
            waterline.move(to: CGPoint(x: tankRect.minX + 4, y: waterlineY))
            waterline.addLine(to: CGPoint(x: tankRect.maxX - 4, y: waterlineY))
            context.stroke(
                waterline,
                with: .color(waterlineColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )

            // 左侧水位标尺（刻度 + 百分比）
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let y = tankRect.maxY - tankRect.height * CGFloat(fraction)
                var tick = Path()
                tick.move(to: CGPoint(x: tankRect.minX, y: y))
                tick.addLine(to: CGPoint(x: tankRect.minX + (fraction == 0 || fraction == 1 ? 12 : 8), y: y))
                context.stroke(tick, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                let label = Text("\(Int(fraction * 100))%")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: 20, y: y), anchor: .trailing)
            }

            // 池体外框
            context.stroke(tankPath, with: .color(Color.secondary.opacity(0.6)), lineWidth: 1.5)
        }
        .frame(height: 200)
        .overlay {
            GeometryReader { geo in
                let tankHeight = geo.size.height - 12
                let y = tankHeight - tankHeight * CGFloat(waterlineFraction) + 6
                Text("水线 \(Format.bytes(waterlineBytes))")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(waterlineColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(waterlineColor)
                    .position(x: geo.size.width - 56, y: y)
            }
        }
    }

    private var waterColor: Color {
        belowWaterline ? .red : .blue
    }

    private var waterlineColor: Color {
        belowWaterline ? .red : .orange
    }
}
