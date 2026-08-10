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
                waterlineBytes: waterlineBytes,
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
        waterlineBytes: Int64,
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
            layer.fill(Path(redRect), with: .color(Color(red: 0.85, green: 0.14, blue: 0.10)))
            layer.fill(Path(whiteRect), with: .color(Color(white: 0.98)))
        }

        // E 形刻痕 + 整刻度数字（每 2 道 E 标一个数字）
        // 注意：stepGB 是 GB 数，循环里必须换算成字节步进，否则会退化成天文数字次循环
        let stepGB = gaugeStepGB(span)
        let stepBytes = stepGB * 1_000_000_000
        var value = (total / stepBytes).rounded(.down) * stepBytes
        var index = 0
        while value >= total - span {
            let y = yForUsed(value)
            let inRed = y < waterlineY
            // 靠近水位线的一行让位：E 与数字都不画，避免与水位线标记重叠
            let nearWaterline = abs(y - waterlineY) < 10
            if y >= gaugeRect.minY + 4 && y <= gaugeRect.maxY - 4 && !nearWaterline {
                drawE(
                    context: &context,
                    at: CGPoint(x: gaugeRect.minX + 11, y: y),
                    color: inRed ? .white : Color(white: 0.13)
                )
                if index % 2 == 0 {
                    drawText(
                        context: &context,
                        text: "\(Int(value / 1_000_000_000))G",
                        at: CGPoint(x: gaugeRect.maxX - 3, y: y),
                        color: inRed ? .white : Color(white: 0.16),
                        size: 7,
                        anchor: .trailing
                    )
                }
            }
            index += 1
            value -= stepBytes
        }

        // 水线标记（跨越标尺的实线）与徽标
        var boundary = Path()
        boundary.move(to: CGPoint(x: gaugeRect.minX, y: waterlineY))
        boundary.addLine(to: CGPoint(x: gaugeRect.maxX, y: waterlineY))
        context.stroke(boundary, with: .color(Color.black.opacity(0.95)), lineWidth: 2.5)
        drawBadge(
            context: &context,
            text: Localized.string("pool.waterline", Format.bytes(waterlineBytes)),
            center: CGPoint(x: gaugeRect.maxX + 34, y: waterlineY + 10)
        )

        // 外框
        context.stroke(gaugePath, with: .color(Color(white: 0.12).opacity(0.9)), lineWidth: 1.5)
    }

    /// 单个 E 形刻痕：竖线 + 三条横线（中短边）；尺寸放大，作为标尺主刻度
    private static func drawE(context: inout GraphicsContext, at p: CGPoint, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - 3.6))
        path.addLine(to: CGPoint(x: p.x, y: p.y + 3.6))
        for dy in [-3.6, 0.0, 3.6] {
            path.move(to: CGPoint(x: p.x, y: p.y + dy))
            path.addLine(to: CGPoint(x: p.x + (abs(dy) < 0.1 ? 2.6 : 4.6), y: p.y + dy))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.4)
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

    /// 白色徽标（黑字）
    private static func drawBadge(context: inout GraphicsContext, text: String, center: CGPoint) {
        PipePainter.drawLabel(context: &context, text: text, center: center)
    }
}
