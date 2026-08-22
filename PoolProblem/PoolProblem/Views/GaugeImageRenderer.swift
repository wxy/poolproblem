import SwiftUI
import DiskReservoirCore

/// E 字型国际水位标尺渲染器：
/// 在数据变化时（扫描完成）预先生成标尺位图，弹窗打开时只做一次 draw，
/// 避免把文本解析/光栅化放在 30fps 渲染或弹窗开场动画里。
enum GaugeImageRenderer {
    @MainActor
    static func render(layout: PoolWindowLayout) -> Image? {
        let canvas = Canvas { context, size in
            drawGauge(context: &context, size: size, layout: layout)
        }
        .frame(width: 700, height: 560)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        return renderer.nsImage.map { Image(nsImage: $0) }
    }

    // MARK: - 绘制

    /// 标尺数值归整显示：≥1G 显示整数 G（如 235G），否则显示整数 M。
    private static func gaugeLabel(_ value: Double) -> String {
        let gb = value / 1_000_000_000
        if gb >= 1 {
            return "\(Int(gb.rounded()))G"
        }
        return "\(Int((value / 1_000_000).rounded()))M"
    }

    /// E 字型国际水位标尺（参考水利行业 E-scale staff gauge）：
    /// 白搪瓷底板 + 黑色 E 形刻痕；水线以上为红色警戒区，E 与数字反白。
    private static func drawGauge(
        context: inout GraphicsContext,
        size: CGSize,
        layout: PoolWindowLayout
    ) {
        let waterlineY = layout.waterlineY
        let waterlineBytes = layout.waterlineBytes
        let total = Double(layout.totalBytes)
        let span = layout.spanBytes
        let yForUsed = layout.y(forBytes:)

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

        // 红黑区统一步长：保证上下 E 大小一致
        let stepGB = GaugeScale.stepGB(
            spanBytes: span,
            usableHeight: Double(layout.usableHeight)
        )
        let stepBytes = stepGB * 1_000_000_000
        let floorValue = max(0, layout.windowBottomBytes)
        var index = 0

        func drawEBlock(
            topY: CGFloat,
            bottomY: CGFloat,
            value: Double,
            red: Bool,
            index: Int
        ) {
            let isLeft = index.isMultiple(of: 2)
            let color = red
                ? Color(red: 0.85, green: 0.14, blue: 0.10)
                : Color(white: 0.13)
            fillLargeE(
                context: &context,
                rect: CGRect(
                    x: isLeft ? leftColumn.minX : rightColumn.minX,
                    y: topY,
                    width: columnWidth,
                    height: bottomY - topY
                ),
                color: color,
                mirrored: !isLeft
            )
            drawVerticalText(
                context: &context,
                text: gaugeLabel(value),
                at: CGPoint(
                    x: isLeft ? rightColumn.midX : leftColumn.midX,
                    y: (topY + bottomY) / 2
                ),
                color: red
                    ? Color(red: 0.85, green: 0.14, blue: 0.10)
                    : Color(white: 0.16),
                size: 7,
                weight: .bold
            )
        }

        // 红/黑分界与水线精确对齐：红色区从水线向上逐块，黑色区从水线向下逐块。
        // 顶部/底部块可能不完整（显示半个 E 或留空），保留空间不再依赖
        // “整 E 数量”恰好等于水位线。
        // 标尺刻度以“已用空间”为坐标：水线对应的已用值 = total - waterlineBytes，
        // 红色区（保留空间）位于该值之上，黑色区在其之下。
        let waterlineUsed = total - Double(waterlineBytes)
        var redBottomValue = waterlineUsed
        while redBottomValue + stepBytes <= total {
            let rawTopY = yForUsed(redBottomValue + stepBytes)
            let rawBottomY = yForUsed(redBottomValue)
            guard rawBottomY - rawTopY > 2,
                  rawBottomY > gaugeRect.minY,
                  rawTopY < gaugeRect.maxY else { break }
            drawEBlock(
                topY: max(rawTopY, gaugeRect.minY),
                bottomY: min(rawBottomY, gaugeRect.maxY),
                value: redBottomValue + stepBytes,
                red: true,
                index: index
            )
            index += 1
            redBottomValue += stepBytes
        }

        var blackTopValue = waterlineUsed
        while blackTopValue > floorValue {
            let rawTopY = yForUsed(blackTopValue)
            let rawBottomY = yForUsed(max(floorValue, blackTopValue - stepBytes))
            guard rawBottomY - rawTopY > 2,
                  rawBottomY > gaugeRect.minY,
                  rawTopY < gaugeRect.maxY else { break }
            drawEBlock(
                topY: max(rawTopY, gaugeRect.minY),
                bottomY: min(rawBottomY, gaugeRect.maxY),
                value: blackTopValue,
                red: false,
                index: index
            )
            index += 1
            blackTopValue -= stepBytes
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
        // 更纤细的 E 字形：被窗口顶截断时仍能看出是半个 E，而不是一团红色方块
        let stemWidth = inset.width * 0.20
        let armHeight = max(4, inset.height * 0.10)
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
