import SwiftUI
import DiskReservoirCore

/// E 字型国际水位标尺渲染器：
/// 在数据变化时（扫描完成）预先生成标尺位图，弹窗打开时只做一次 draw，
/// 避免把文本解析/光栅化放在 30fps 渲染或弹窗开场动画里。
enum GaugeImageRenderer {
    /// 与 PoolTankView 保持一致的"可视窗口覆盖的已用空间跨度"
    static func windowSpanBytes(availableBytes: Int64, cleanableItems: [ScanItem]) -> Int64 {
        let cleanableTotal = cleanableItems.reduce(Int64(0)) { $0 + max($1.reclaimableBytes, 0) }
        return max(availableBytes + cleanableTotal + 20_000_000_000, 30_000_000_000)
    }

    @MainActor
    static func render(
        totalBytes: Int64,
        waterlineBytes: Int64,
        availableBytes: Int64,
        cleanableItems: [ScanItem]
    ) -> Image? {
        let span = Double(max(windowSpanBytes(availableBytes: availableBytes, cleanableItems: cleanableItems), 1))
        let canvas = Canvas { context, size in
            let waterlineUsed = Double(max(0, totalBytes - waterlineBytes))
            let usedBytes = max(0, totalBytes - availableBytes)
            let topInset: CGFloat = 26
            let usableH = max(1, size.height - topInset)
            func yForUsed(_ value: Double) -> CGFloat {
                let fraction = (Double(totalBytes) - value) / span
                return topInset + CGFloat(min(max(fraction, 0), 1)) * usableH
            }
            drawGauge(
                context: &context,
                size: size,
                waterlineY: yForUsed(waterlineUsed),
                availableY: yForUsed(Double(usedBytes)),
                waterlineBytes: waterlineBytes,
                availableBytes: availableBytes,
                usedBytes: usedBytes,
                total: Double(totalBytes),
                span: span,
                yForUsed: yForUsed
            )
        }
        .frame(width: 700, height: 560)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        return renderer.nsImage.map { Image(nsImage: $0) }
    }

    // MARK: - 绘制

    /// E 字型标尺的单位间隔：让窗口跨度内大约有 8~16 道 E 刻痕
    private static func gaugeStepGB(_ span: Double) -> Double {
        let raw = span / 1_000_000_000
        for candidate in [2.0, 5.0, 10.0, 20.0, 50.0, 100.0] where raw / candidate <= 16 {
            return candidate
        }
        return 100
    }

    /// E 字型国际水位标尺（参考水利行业 E-scale staff gauge）：
    /// 白搪瓷底板 + 黑色 E 形刻痕；水线以上为红色警戒区，E 与数字反白。
    private static func drawGauge(
        context: inout GraphicsContext,
        size: CGSize,
        waterlineY: CGFloat,
        availableY: CGFloat,
        waterlineBytes: Int64,
        availableBytes: Int64,
        usedBytes: Int64,
        total: Double,
        span: Double,
        yForUsed: (Double) -> CGFloat
    ) {
        // 标尺下移并加小圆角，避开弹窗左上圆角；加宽让 E 与数字留出间隔
        let gaugeRect = CGRect(x: 8, y: 14, width: 40, height: size.height - 28)
        let gaugePath = Path(roundedRect: gaugeRect, cornerRadius: 3)
        let redRect = CGRect(
            x: gaugeRect.minX, y: gaugeRect.minY,
            width: gaugeRect.width, height: max(0, waterlineY - gaugeRect.minY)
        )
        let whiteRect = CGRect(
            x: gaugeRect.minX, y: max(waterlineY, gaugeRect.minY),
            width: gaugeRect.width, height: max(0, gaugeRect.maxY - max(waterlineY, gaugeRect.minY))
        )
        // 在独立图层里裁剪圆角底板，避免影响后续绘制
        context.drawLayer { layer in
            layer.clip(to: gaugePath)
            layer.fill(Path(redRect), with: .color(Color(white: 0.98)))
            layer.fill(Path(whiteRect), with: .color(Color(white: 0.98)))
        }

        // 两个 E 分别放在左右两列，形成镜像对角；每个 E 对面写对应容量。
        let columnWidth = gaugeRect.width / 2
        let leftColumn = CGRect(
            x: gaugeRect.minX,
            y: gaugeRect.minY,
            width: columnWidth,
            height: gaugeRect.height
        )
        let rightColumn = CGRect(
            x: gaugeRect.midX,
            y: gaugeRect.minY,
            width: columnWidth,
            height: gaugeRect.height
        )

        let stepGB = gaugeStepGB(span)
        let stepBytes = stepGB * 1_000_000_000
        var value = (total / stepBytes).rounded(.down) * stepBytes
        var index = 0
        let floorValue = max(0, total - span)
        while value >= floorValue {
            let blockTopY = yForUsed(value)
            let nextValue = max(floorValue, value - stepBytes)
            let blockBottomY = yForUsed(nextValue)
            guard blockBottomY - blockTopY > 2 else { break }

            let isLeft = index.isMultiple(of: 2)
            // 按块中点判定红/黑，避免横跨水位线的块整块变红，
            // 导致红黑分界低于水位线标记（标记看起来“偏上”）。
            let inRed = (blockTopY + blockBottomY) / 2 < waterlineY
            let color = inRed
                ? Color(red: 0.85, green: 0.14, blue: 0.10)
                : Color(white: 0.13)
            fillLargeE(
                context: &context,
                rect: CGRect(
                    x: isLeft ? leftColumn.minX : rightColumn.minX,
                    y: blockTopY,
                    width: columnWidth,
                    height: blockBottomY - blockTopY
                ),
                color: color,
                mirrored: !isLeft
            )
            drawVerticalText(
                context: &context,
                text: Format.bytes(Int64(value)),
                at: CGPoint(
                    x: isLeft ? rightColumn.midX : leftColumn.midX,
                    y: (blockTopY + blockBottomY) / 2
                ),
                color: inRed
                    ? Color(red: 0.85, green: 0.14, blue: 0.10)
                    : Color(white: 0.16),
                size: 7,
                weight: .bold
            )

            index += 1
            value -= stepBytes
        }

        // 水线标记（跨越标尺的实线）与徽标
        var boundary = Path()
        boundary.move(to: CGPoint(x: gaugeRect.minX, y: waterlineY))
        boundary.addLine(to: CGPoint(x: gaugeRect.maxX, y: waterlineY))
        context.stroke(boundary, with: .color(Color.black.opacity(0.95)), lineWidth: 2.5)
        var arrow = Path()
        arrow.move(to: CGPoint(x: gaugeRect.maxX, y: waterlineY))
        arrow.addLine(to: CGPoint(x: gaugeRect.maxX + 10, y: waterlineY - 3))
        arrow.addLine(to: CGPoint(x: gaugeRect.maxX + 10, y: waterlineY + 3))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Color.black.opacity(0.95)))
        drawBadge(
            context: &context,
            text: Localized.string("pool.waterline", Format.bytes(waterlineBytes)),
            center: CGPoint(x: gaugeRect.maxX + 32, y: waterlineY)
        )

        // 外框
        context.stroke(gaugePath, with: .color(Color(white: 0.12).opacity(0.9)), lineWidth: 1.5)
    }

    /// 填充一个大 E 容量分区块；mirrored 为 true 时，E 的竖线在右侧，三条横线向左延伸。
    private static func fillLargeE(
        context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        mirrored: Bool
    ) {
        guard rect.height > 0 else { return }
        let inset = rect
        guard inset.height > 0 else { return }
        let stemWidth = inset.width * 0.34
        let armHeight = max(5, inset.height * 0.18)
        let stemRect: CGRect
        if mirrored {
            stemRect = CGRect(
                x: inset.maxX - stemWidth,
                y: inset.minY,
                width: stemWidth,
                height: inset.height
            )
        } else {
            stemRect = CGRect(
                x: inset.minX,
                y: inset.minY,
                width: stemWidth,
                height: inset.height
            )
        }
        context.fill(Path(stemRect), with: .color(color))

        let armYs = [
            inset.minY,
            inset.midY - armHeight / 2,
            inset.maxY - armHeight,
        ]
        for armY in armYs {
            let armRect: CGRect
            if mirrored {
                armRect = CGRect(
                    x: inset.minX,
                    y: armY,
                    width: inset.width - stemWidth,
                    height: armHeight
                )
            } else {
                armRect = CGRect(
                    x: stemRect.maxX,
                    y: armY,
                    width: inset.width - stemWidth,
                    height: armHeight
                )
            }
            context.fill(Path(armRect), with: .color(color))
        }
    }

    /// 画布内直接绘制文本（可选锚点）
    private static func drawText(
        context: inout GraphicsContext,
        text: String,
        at point: CGPoint,
        color: Color,
        size: CGFloat,
        weight: Font.Weight = .semibold,
        anchor: UnitPoint = .center
    ) {
        let label = Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
        let resolved = context.resolve(label)
        context.draw(resolved, at: point, anchor: anchor)
    }

    /// 竖向绘制容量数字，避免在半个标尺宽度里挤不下。
    private static func drawVerticalText(
        context: inout GraphicsContext,
        text: String,
        at point: CGPoint,
        color: Color,
        size: CGFloat,
        weight: Font.Weight = .bold
    ) {
        let label = Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
        let resolved = context.resolve(label)
        context.drawLayer { layer in
            layer.translateBy(x: point.x, y: point.y)
            layer.rotate(by: .degrees(-90))
            layer.draw(resolved, at: .zero, anchor: .center)
        }
    }

    /// 白色徽标（黑字）
    private static func drawBadge(context: inout GraphicsContext, text: String, center: CGPoint) {
        PipePainter.drawLabel(context: &context, text: text, center: center)
    }
}
