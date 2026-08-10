import SwiftUI
import DiskReservoirCore

struct CleanableLayer: Identifiable {
    let id: Int
    let name: String
    let bytes: Int64
    let color: Color
    let safety: SafetyLevel
}

enum PoolLayers {
    static let palette: [Color] = [
        Color(red: 0.22, green: 0.72, blue: 0.33),
        Color(red: 0.30, green: 0.80, blue: 0.45),
        Color(red: 0.42, green: 0.82, blue: 0.60),
        Color(red: 0.55, green: 0.85, blue: 0.55),
        Color(red: 0.55, green: 0.88, blue: 0.72),
        Color(red: 0.50, green: 0.82, blue: 0.88),
        Color(red: 0.40, green: 0.75, blue: 0.90),
        Color(red: 0.52, green: 0.80, blue: 0.95),
        Color(red: 0.62, green: 0.86, blue: 1.00),
        Color(red: 0.72, green: 0.90, blue: 1.00),
        Color(red: 0.82, green: 0.94, blue: 1.00),
    ]

    static let nonCleanableColor = Color(red: 0.10, green: 0.22, blue: 0.50)

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
                color: palette[index % palette.count],
                safety: item.safety
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

    var body: some View {
        Canvas { context, size in
            let tankRect = CGRect(
                x: 4,
                y: 6,
                width: size.width - 8,
                height: size.height - 12
            )
            let tankPath = Path(roundedRect: tankRect, cornerRadius: 10)
            let waterlineY = tankRect.maxY - tankRect.height * CGFloat(waterlineFraction)
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

            context.clip(to: tankPath)

            // 1) 池内背景 = 红白水位标尺（水位线以上红、以下白）
            let whiteRect = CGRect(
                x: tankRect.minX, y: waterlineY,
                width: tankRect.width, height: tankRect.maxY - waterlineY
            )
            context.fill(Path(whiteRect), with: .color(.white))
            let redRect = CGRect(
                x: tankRect.minX, y: tankRect.minY,
                width: tankRect.width, height: waterlineY - tankRect.minY
            )
            context.fill(Path(redRect), with: .color(.red))

            // 2) 刻度线 + GB 数字
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let y = tankRect.maxY - tankRect.height * CGFloat(fraction)
                let onRed = y <= waterlineY
                var tick = Path()
                tick.move(to: CGPoint(x: tankRect.minX + 2, y: y))
                tick.addLine(to: CGPoint(x: tankRect.maxX - 2, y: y))
                context.stroke(
                    tick,
                    with: .color(onRed ? Color.white : Color.black.opacity(0.55)),
                    lineWidth: 1.2
                )
                let gb = Int(Double(totalBytes) * fraction / 1_000_000_000)
                let label = Text("\(gb)G")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(onRed ? Color.white : Color.black.opacity(0.65))
                context.draw(label, at: CGPoint(x: tankRect.minX + 24, y: y), anchor: .leading)
            }

            // 3) 分层（半透明，透过可见标尺）
            let nonCleanableHeight = waterHeight * CGFloat(Double(nonCleanable) / usedD)
            context.fill(
                Path(CGRect(
                    x: tankRect.minX,
                    y: tankRect.maxY - nonCleanableHeight,
                    width: tankRect.width,
                    height: nonCleanableHeight
                )),
                with: .color(PoolLayers.nonCleanableColor.opacity(0.65))
            )
            var cursor = tankRect.maxY - nonCleanableHeight
            for layer in layers {
                let h = waterHeight * CGFloat(Double(layer.bytes) / usedD * scale)
                context.fill(
                    Path(CGRect(
                        x: tankRect.minX,
                        y: cursor - h,
                        width: tankRect.width,
                        height: h
                    )),
                    with: .color(layer.color.opacity(0.55))
                )
                cursor -= h
            }

            // 4) 水位线边界 + 标签
            var boundary = Path()
            boundary.move(to: CGPoint(x: tankRect.minX, y: waterlineY))
            boundary.addLine(to: CGPoint(x: tankRect.maxX, y: waterlineY))
            context.stroke(boundary, with: .color(.black.opacity(0.85)), lineWidth: 1.5)
            let tag = Text("水线 \(Format.bytes(waterlineBytes))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
            context.draw(tag, at: CGPoint(x: tankRect.maxX - 6, y: waterlineY + 9), anchor: .trailing)

            context.stroke(tankPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
    }
}
