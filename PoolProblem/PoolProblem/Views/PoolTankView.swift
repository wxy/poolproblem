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
        Color(red: 0.05, green: 0.36, blue: 0.20),
        Color(red: 0.10, green: 0.52, blue: 0.28),
        Color(red: 0.18, green: 0.65, blue: 0.34),
        Color(red: 0.32, green: 0.76, blue: 0.44),
        Color(red: 0.48, green: 0.84, blue: 0.54),
        Color(red: 0.34, green: 0.76, blue: 0.68),
        Color(red: 0.40, green: 0.80, blue: 0.80),
        Color(red: 0.54, green: 0.86, blue: 0.90),
        Color(red: 0.68, green: 0.91, blue: 0.95),
        Color(red: 0.80, green: 0.94, blue: 0.98),
        Color(red: 0.90, green: 0.97, blue: 1.00),
    ]

    static let nonCleanableColor = Color(red: 0.05, green: 0.12, blue: 0.30)

    static func layerOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.7 }
        let progress = Double(index) / Double(count - 1)
        return 0.95 - progress * 0.45   // 底层 0.95 → 表层 0.5
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

    /// 可视窗口覆盖的"已用空间"跨度：
    /// 从水面附近（可用 + 可清理）向下再多露出 20GB 不可清理，证明上方都可清理/可用
    private var windowSpanBytes: Int64 {
        let cleanableTotal = cleanableItems.reduce(Int64(0)) { $0 + max($1.reclaimableBytes, 0) }
        let span = availableBytes + cleanableTotal + 20_000_000_000
        return max(span, 30_000_000_000)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                render(context: &context, size: size, phase: phase)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func render(context: inout GraphicsContext, size: CGSize, phase: Double) {
        let tankRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let tankPath = Path(tankRect)
        let span = Double(max(windowSpanBytes, 1))
        let used = Double(max(0, totalBytes - availableBytes))
        let waterlineUsed = Double(max(0, totalBytes - waterlineBytes))
        // 标尺顶部留出空间（徽标不顶到窗口圆角）
        let topInset: CGFloat = 26
        let usableH = max(1, size.height - topInset)

        // 已用空间越大，越靠近窗口顶部（池顶）；窗口显示 [total-span, total] 这一段
        func yForUsed(_ value: Double) -> CGFloat {
            let fraction = (Double(totalBytes) - value) / span
            return topInset + CGFloat(min(max(fraction, 0), 1)) * usableH
        }

        let surfaceY = yForUsed(used)
        let waterlineY = yForUsed(waterlineUsed)
        let (layers, nonCleanable) = PoolLayers.make(
            items: cleanableItems,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            estimatedRecipeIDs: estimatedRecipeIDs
        )

        // 全程只设置一次裁剪
        context.clip(to: tankPath)

        // 1) 不透明池体（水面以上为空气）
        context.fill(tankPath, with: .color(Color(white: 0.96)))

        // 2) 红白窄条标尺（左侧，水层之下；红色 = 警戒区在水线之上）
        let stripRect = CGRect(x: 4, y: 6, width: 26, height: size.height - 12)
        let stripPath = Path(stripRect)
        let stripRed = CGRect(
            x: stripRect.minX, y: stripRect.minY,
            width: stripRect.width, height: max(0, waterlineY - stripRect.minY)
        )
        let stripWhite = CGRect(
            x: stripRect.minX, y: max(waterlineY, stripRect.minY),
            width: stripRect.width, height: max(0, stripRect.maxY - max(waterlineY, stripRect.minY))
        )
        context.fill(Path(stripRed), with: .color(.red))
        context.fill(Path(stripWhite), with: .color(.white))
        // 顶部留白区也画刻度（徽标之外仍有标尺）
        for extraY in [CGFloat(10), 18] {
            var tick = Path()
            tick.move(to: CGPoint(x: stripRect.minX + 1, y: extraY))
            tick.addLine(to: CGPoint(x: stripRect.maxX - 5, y: extraY))
            context.stroke(tick, with: .color(.black.opacity(0.5)), lineWidth: 1)
        }
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let value = Double(totalBytes) - fraction * span
            let y = yForUsed(value)
            let isMajor = fraction.truncatingRemainder(dividingBy: 0.25) == 0
            var tick = Path()
            tick.move(to: CGPoint(x: stripRect.minX + 1, y: y))
            tick.addLine(to: CGPoint(x: stripRect.maxX - (isMajor ? 1 : 5), y: y))
            context.stroke(
                tick,
                with: .color(isMajor ? Color.black.opacity(0.8) : Color.black.opacity(0.5)),
                lineWidth: isMajor ? 1.6 : 1
            )
        }
        context.stroke(stripPath, with: .color(.black.opacity(0.7)), lineWidth: 1.5)

        // 3) GB 数字徽标与水线徽标（直角，水层之下）
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let value = Double(totalBytes) - fraction * span
            let y = yForUsed(value)
            drawBadge(
                context: &context,
                text: "\(Int(value / 1_000_000_000))G",
                center: CGPoint(x: stripRect.midX, y: y)
            )
        }
        var boundary = Path()
        boundary.move(to: CGPoint(x: stripRect.minX, y: waterlineY))
        boundary.addLine(to: CGPoint(x: stripRect.maxX, y: waterlineY))
        context.stroke(boundary, with: .color(.black.opacity(0.9)), lineWidth: 1.5)
        drawBadge(
            context: &context,
            text: "水线 \(Format.bytes(waterlineBytes))",
            center: CGPoint(x: stripRect.maxX + 30, y: waterlineY + 10)
        )

        // 4) 水体渐变（从水面到底部；下方更深处被窗口截断）
        let waterBody = CGRect(
            x: 0,
            y: surfaceY,
            width: size.width,
            height: max(0, size.height - surfaceY)
        )
        if waterBody.height > 0 {
            context.fill(
                Path(waterBody),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.02, green: 0.22, blue: 0.18).opacity(0.6),
                        Color(red: 0.10, green: 0.52, blue: 0.42).opacity(0.4),
                        Color(red: 0.55, green: 0.84, blue: 0.84).opacity(0.18),
                    ]),
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: 0, y: surfaceY)
                )
            )
        }

        // 5) 容量分层（半透明，水面之下，层间画分隔线）
        var boundaries: [CGFloat] = []
        var bottomUsed = 0.0
        let nonCleanableTop = bottomUsed + Double(nonCleanable)
        boundaries.append(yForUsed(nonCleanableTop))
        fillLayer(
            context: &context,
            bottomUsed: bottomUsed,
            topUsed: nonCleanableTop,
            yForUsed: yForUsed,
            color: PoolLayers.nonCleanableColor.opacity(0.9)
        )
        bottomUsed = nonCleanableTop
        for (index, layer) in layers.enumerated() {
            let top = bottomUsed + Double(layer.bytes)
            boundaries.append(yForUsed(top))
            fillLayer(
                context: &context,
                bottomUsed: bottomUsed,
                topUsed: top,
                yForUsed: yForUsed,
                color: layer.color.opacity(PoolLayers.layerOpacity(index: index, count: layers.count))
            )
            bottomUsed = top
        }
        // 层间分隔线（静止，1px = 0.5pt；只有水面波动）
        for boundaryY in boundaries {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: boundaryY))
            line.addLine(to: CGPoint(x: size.width, y: boundaryY))
            context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 0.5)
        }

        // 6) 水面波纹动效（水的最上层）
        var wave = Path()
        wave.move(to: CGPoint(x: 0, y: surfaceY))
        var x: CGFloat = 0
        while x <= size.width {
            let y = surfaceY + sin((x + CGFloat(phase) * 90) * 0.05) * 2.5
            wave.addLine(to: CGPoint(x: x, y: y))
            x += 4
        }
        context.stroke(wave, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        var band = wave
        band.addLine(to: CGPoint(x: size.width, y: surfaceY + 8))
        band.addLine(to: CGPoint(x: 0, y: surfaceY + 8))
        band.closeSubpath()
        context.fill(band, with: .color(.white.opacity(0.12)))

        // 水池外框（可见窗口的边界）
        context.stroke(tankPath, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
    }

    private func fillLayer(
        context: inout GraphicsContext,
        bottomUsed: Double,
        topUsed: Double,
        yForUsed: (Double) -> CGFloat,
        color: Color
    ) {
        let yTop = yForUsed(topUsed)
        let yBottom = yForUsed(bottomUsed)
        let rect = CGRect(x: 0, y: yTop, width: 10_000, height: max(0, yBottom - yTop))
        context.fill(Path(rect), with: .color(color))
    }

    private func drawBadge(context: inout GraphicsContext, text: String, center: CGPoint) {
        let label = Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: CGSize(width: 120, height: 20))
        let badgeRect = CGRect(
            x: center.x - (textSize.width + 8) / 2,
            y: center.y - (textSize.height + 2) / 2,
            width: textSize.width + 8,
            height: textSize.height + 2
        )
        let badgePath = Path(badgeRect)
        context.fill(badgePath, with: .color(.white.opacity(0.92)))
        context.stroke(badgePath, with: .color(.gray.opacity(0.7)), lineWidth: 0.5)
        context.draw(resolved, at: center, anchor: .center)
    }
}
