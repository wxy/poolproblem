import SwiftUI
import DiskReservoirCore

struct CleanableLayer: Identifiable {
    let id: Int
    let name: String
    let bytes: Int64
    let color: Color
    let safety: SafetyLevel
    let estimated: Bool
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

    static func make(
        items: [ScanItem],
        totalBytes: Int64,
        availableBytes: Int64,
        estimatedRecipeIDs: Set<String>
    ) -> (layers: [CleanableLayer], nonCleanableBytes: Int64) {
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
                safety: item.safety,
                estimated: estimatedRecipeIDs.contains(item.recipeID)
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
    let estimatedRecipeIDs: Set<String>

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
                availableBytes: availableBytes,
                estimatedRecipeIDs: estimatedRecipeIDs
            )
            let waterHeight = tankRect.height * CGFloat(min(max(usedFraction, 0), 1))
            let sumLayer = layers.reduce(Int64(0)) { $0 + $1.bytes }
            let scale = used > 0 && sumLayer > used ? Double(used) / Double(sumLayer) : 1.0
            let stripRect = CGRect(
                x: tankRect.minX + 4,
                y: tankRect.minY + 6,
                width: 20,
                height: tankRect.height - 12
            )

            context.clip(to: tankPath)

            // 1) 池体底色
            context.fill(tankPath, with: .color(Color.secondary.opacity(0.06)))

            // 2) 分层（半透明）
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

            // 3) 红白窄条标尺（贴水池左侧，画在水层之上保证清晰）
            let stripPath = Path(roundedRect: stripRect, cornerRadius: 4)
            context.clip(to: stripPath)
            let stripWhite = CGRect(
                x: stripRect.minX, y: waterlineY,
                width: stripRect.width, height: stripRect.maxY - waterlineY
            )
            context.fill(Path(stripWhite), with: .color(.white))
            let stripRed = CGRect(
                x: stripRect.minX, y: stripRect.minY,
                width: stripRect.width, height: waterlineY - stripRect.minY
            )
            context.fill(Path(stripRed), with: .color(.red))
            for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
                let y = stripRect.maxY - stripRect.height * CGFloat(fraction)
                let onRed = y <= waterlineY
                let isMajor = fraction.truncatingRemainder(dividingBy: 0.25) == 0
                var tick = Path()
                tick.move(to: CGPoint(x: stripRect.minX + 1, y: y))
                tick.addLine(to: CGPoint(
                    x: stripRect.maxX - (isMajor ? 1 : 5),
                    y: y
                ))
                context.stroke(
                    tick,
                    with: .color(onRed ? Color.white : Color.black.opacity(0.7)),
                    lineWidth: isMajor ? 1.6 : 1
                )
                if isMajor {
                    let gb = Int(Double(totalBytes) * fraction / 1_000_000_000)
                    let label = Text("\(gb)G")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(onRed ? Color.white : Color.black.opacity(0.8))
                    context.draw(label, at: CGPoint(x: stripRect.maxX + 4, y: y), anchor: .leading)
                }
            }
            context.stroke(stripPath, with: .color(.secondary.opacity(0.8)), lineWidth: 1)

            // 4) 水位线分界 + 标签
            context.clip(to: tankPath)
            var boundary = Path()
            boundary.move(to: CGPoint(x: stripRect.minX, y: waterlineY))
            boundary.addLine(to: CGPoint(x: stripRect.maxX, y: waterlineY))
            context.stroke(boundary, with: .color(.black.opacity(0.9)), lineWidth: 1.5)
            let tag = Text("水线 \(Format.bytes(waterlineBytes))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
            context.draw(tag, at: CGPoint(x: stripRect.maxX + 4, y: waterlineY + 10), anchor: .leading)

            context.stroke(tankPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
    }
}
