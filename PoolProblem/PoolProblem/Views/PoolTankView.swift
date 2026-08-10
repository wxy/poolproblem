import SwiftUI
import DiskReservoirCore

struct CleanableLayer: Identifiable {
    let id: Int
    let name: String
    let bytes: Int64
    let color: Color
}

enum PoolLayers {
    static let palette: [Color] = [
        .blue, .cyan, .teal, .mint, .green,
        .yellow, .orange, .red, .purple, .pink, .indigo,
    ]

    static func make(items: [ScanItem], totalBytes: Int64, availableBytes: Int64)
        -> (layers: [CleanableLayer], nonCleanableBytes: Int64) {
        let used = max(0, totalBytes - availableBytes)
        let cleanable = items
            .filter { $0.reclaimableBytes > 0 }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        var layers: [CleanableLayer] = []
        var sum: Int64 = 0
        for (index, item) in cleanable.enumerated() {
            layers.append(CleanableLayer(
                id: index,
                name: item.name,
                bytes: item.reclaimableBytes,
                color: palette[index % palette.count]
            ))
            sum += item.reclaimableBytes
        }
        return (layers, max(0, used - sum))
    }
}

struct PoolTankView: View {
    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let cleanableItems: [ScanItem]

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
        HStack(alignment: .top, spacing: 6) {
            gauge
            tank
        }
        .frame(height: 360)
    }

    private var gauge: some View {
        Canvas { context, size in
            let barRect = CGRect(x: 0, y: 4, width: 10, height: size.height - 8)
            let waterlineY = barRect.maxY - barRect.height * CGFloat(waterlineFraction)
            let barPath = Path(roundedRect: barRect, cornerRadius: 5)
            context.clip(to: barPath)
            // 水位标线以上红色，以下白色
            let whiteRect = CGRect(
                x: barRect.minX, y: waterlineY,
                width: barRect.width, height: barRect.maxY - waterlineY
            )
            context.fill(Path(whiteRect), with: .color(.white))
            let redRect = CGRect(
                x: barRect.minX, y: barRect.minY,
                width: barRect.width, height: waterlineY - barRect.minY
            )
            context.fill(Path(redRect), with: .color(.red))
            context.stroke(barPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            // GB 刻度
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let y = barRect.maxY - barRect.height * CGFloat(fraction)
                var tick = Path()
                tick.move(to: CGPoint(x: barRect.maxX, y: y))
                tick.addLine(to: CGPoint(x: barRect.maxX + 4, y: y))
                context.stroke(tick, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
                let gb = Int(Double(totalBytes) * fraction / 1_000_000_000)
                let label = Text("\(gb)G")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: barRect.maxX + 20, y: y), anchor: .trailing)
            }
        }
        .frame(width: 46)
    }

    private var tank: some View {
        GeometryReader { geo in
            let tankRect = CGRect(
                x: 2,
                y: 4,
                width: geo.size.width - 4,
                height: geo.size.height - 8
            )
            let tankPath = Path(roundedRect: tankRect, cornerRadius: 10)
            let used = max(0, totalBytes - availableBytes)
            let usedD = Double(max(used, 1))
            let (layers, nonCleanable) = PoolLayers.make(
                items: cleanableItems,
                totalBytes: totalBytes,
                availableBytes: availableBytes
            )
            let waterHeight = tankRect.height * CGFloat(min(max(usedFraction, 0), 1))
            let sumLayer = layers.reduce(Int64(0)) { $0 + $1.bytes }
            let scale = used > 0 && sumLayer > used ? Double(used) / Double(sumLayer) : 1.0

            ZStack(alignment: .bottom) {
                // 池体背景
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.06))

                Canvas { context, _ in
                    context.clip(to: tankPath)
                    // 底部：不可清理
                    let nonCleanableHeight = waterHeight * CGFloat(Double(nonCleanable) / usedD)
                    context.fill(
                        Path(CGRect(
                            x: tankRect.minX,
                            y: tankRect.maxY - nonCleanableHeight,
                            width: tankRect.width,
                            height: nonCleanableHeight
                        )),
                        with: .color(.gray.opacity(0.55))
                    )
                    // 鸡尾酒分层：可清理项
                    var cursor = tankRect.maxY - nonCleanableHeight
                    for layer in layers {
                        let h = waterHeight * CGFloat(Double(layer.bytes) / usedD * scale)
                        let layerRect = CGRect(
                            x: tankRect.minX,
                            y: cursor - h,
                            width: tankRect.width,
                            height: h
                        )
                        context.fill(Path(layerRect), with: .color(layer.color))
                        cursor -= h
                    }
                    // 水位标线
                    let waterlineY = tankRect.maxY - tankRect.height * CGFloat(waterlineFraction)
                    var line = Path()
                    line.move(to: CGPoint(x: tankRect.minX + 3, y: waterlineY))
                    line.addLine(to: CGPoint(x: tankRect.maxX - 3, y: waterlineY))
                    context.stroke(
                        line,
                        with: .color(waterlineColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    context.stroke(tankPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            let tankHeight = 360.0 - 8.0
            let y = tankHeight - tankHeight * waterlineFraction + 4
            Text("水线 \(Format.bytes(waterlineBytes))")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(waterlineColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(waterlineColor)
                .offset(y: y - 6)
        }
    }

    private var waterlineColor: Color {
        belowWaterline ? .red : .orange
    }
}
