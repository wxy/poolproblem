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
    // 由深到浅：底层深绿 → 表层清透（模拟光线穿透）
    static let palette: [Color] = [
        Color(red: 0.08, green: 0.42, blue: 0.22),
        Color(red: 0.14, green: 0.60, blue: 0.30),
        Color(red: 0.24, green: 0.72, blue: 0.38),
        Color(red: 0.42, green: 0.82, blue: 0.50),
        Color(red: 0.55, green: 0.88, blue: 0.58),
        Color(red: 0.42, green: 0.82, blue: 0.76),
        Color(red: 0.48, green: 0.86, blue: 0.86),
        Color(red: 0.62, green: 0.90, blue: 0.93),
        Color(red: 0.76, green: 0.93, blue: 0.97),
        Color(red: 0.86, green: 0.96, blue: 0.99),
        Color(red: 0.93, green: 0.98, blue: 1.00),
    ]

    static let nonCleanableColor = Color(red: 0.05, green: 0.12, blue: 0.30)

    static func layerOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.6 }
        let progress = Double(index) / Double(count - 1)
        return 0.9 - progress * 0.55   // 底层 0.9 → 表层 0.35
    }

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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                render(context: &context, size: size, phase: phase)
            }
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
    }

    private func render(context: inout GraphicsContext, size: CGSize, phase: Double) {
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
            width: 26,
            height: tankRect.height - 12
        )
        context.clip(to: tankPath)

        // 1) 先绘制不透明的池体
        context.fill(tankPath, with: .color(Color(white: 0.96)))

        // 2) 再在池体左侧绘制红白窄条标尺（水层之下）
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
            tick.addLine(to: CGPoint(x: stripRect.maxX - (isMajor ? 1 : 5), y: y))
            context.stroke(
                tick,
                with: .color(onRed ? Color.white : Color.black.opacity(0.7)),
                lineWidth: isMajor ? 1.6 : 1
            )
        }
        context.stroke(stripPath, with: .color(.secondary.opacity(0.8)), lineWidth: 1)

        // 3) 最后在整个水池范围内绘制水层（半透明，覆盖标尺）
        context.clip(to: tankPath)
        let nonCleanableHeight = waterHeight * CGFloat(Double(nonCleanable) / usedD)
        context.fill(
            Path(CGRect(
                x: tankRect.minX,
                y: tankRect.maxY - nonCleanableHeight,
                width: tankRect.width,
                height: nonCleanableHeight
            )),
            with: .color(PoolLayers.nonCleanableColor.opacity(0.95))
        )
        var cursor = tankRect.maxY - nonCleanableHeight
        for (index, layer) in layers.enumerated() {
            let h = waterHeight * CGFloat(Double(layer.bytes) / usedD * scale)
            context.fill(
                Path(CGRect(
                    x: tankRect.minX,
                    y: cursor - h,
                    width: tankRect.width,
                    height: h
                )),
                with: .color(layer.color.opacity(PoolLayers.layerOpacity(index: index, count: layers.count)))
            )
            cursor -= h
        }

        // 5) 水面波纹动效
        let surfaceY = cursor
        var wave = Path()
        wave.move(to: CGPoint(x: tankRect.minX, y: surfaceY))
        var x: CGFloat = tankRect.minX
        while x <= tankRect.maxX {
            let y = surfaceY + sin((x + CGFloat(phase) * 90) * 0.05) * 2.5
            wave.addLine(to: CGPoint(x: x, y: y))
            x += 4
        }
        context.stroke(wave, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        var band = wave
        band.addLine(to: CGPoint(x: tankRect.maxX, y: surfaceY + 8))
        band.addLine(to: CGPoint(x: tankRect.minX, y: surfaceY + 8))
        band.closeSubpath()
        context.fill(band, with: .color(.white.opacity(0.12)))

        // 6) 刻度数字 + 水位线分界 + 标签（画在水层之上保证可读）
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = stripRect.maxY - stripRect.height * CGFloat(fraction)
            let onRed = y <= waterlineY
            let gb = Int(Double(totalBytes) * fraction / 1_000_000_000)
            let label = Text("\(gb)G")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(onRed ? Color.white : Color.black.opacity(0.8))
            context.draw(label, at: CGPoint(x: stripRect.midX, y: y), anchor: .center)
        }
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
}
