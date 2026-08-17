import SwiftUI
import DiskReservoirCore

struct CleanableLayer: Identifiable {
    let id: Int
    let itemID: String
    let recipeID: String
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
        Color(red: 0.40, green: 0.80, blue: 0.78),
        Color(red: 0.52, green: 0.86, blue: 0.80),
        Color(red: 0.64, green: 0.90, blue: 0.84),
        Color(red: 0.77, green: 0.94, blue: 0.89),
        Color(red: 0.88, green: 0.97, blue: 0.93),
    ]

    static let nonCleanableColor = Color(red: 0.05, green: 0.12, blue: 0.30)
    static let trashColor = Color(red: 0.55, green: 0.78, blue: 0.95)

    static func layerOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.7 }
        let progress = Double(index) / Double(count - 1)
        return 0.95 - progress * 0.45   // 底层 0.95 → 表层 0.5
    }

    static func make(
        items: [ScanItem],
        totalBytes: Int64,
        availableBytes: Int64,
        estimatedRecipeIDs: Set<String>,
        excludedItemIDs: Set<String> = []
    ) -> (layers: [CleanableLayer], nonCleanableBytes: Int64, trashBytes: Int64) {
        let used = max(0, totalBytes - availableBytes)
        let cleanable = items
            .filter {
                $0.reclaimableBytes > 0
                    && !excludedItemIDs.contains($0.id)
                    && $0.recipeID != "trash"
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        var layers: [CleanableLayer] = []
        var sum: Int64 = 0
        for (index, item) in cleanable.enumerated() {
            layers.append(CleanableLayer(
                id: index,
                itemID: item.id,
                recipeID: item.recipeID,
                name: item.name,
                bytes: item.reclaimableBytes,
                color: item.recipeID == "trash" ? trashColor : palette[index % palette.count],
                safety: item.safety,
                estimated: estimatedRecipeIDs.contains(item.recipeID)
            ))
            sum += item.reclaimableBytes
        }
        let trashBytes = items
            .filter { $0.recipeID == "trash" && $0.reclaimableBytes > 0 && !excludedItemIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        return (layers, max(0, used - sum - trashBytes), trashBytes)
    }
}

struct PoolTankView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let cleanableItems: [ScanItem]
    let estimatedRecipeIDs: Set<String>
    let inflowLabels: [(name: String, bytes: Int64)]
    let excludedItemIDs: Set<String>
    let gaugeImage: Image?

    /// 可视窗口覆盖的"已用空间"跨度：
    /// 从水面附近（可用 + 可清理）向下再多露出 20GB 不可清理，证明上方都可清理/可用
    private var windowSpanBytes: Int64 {
        GaugeImageRenderer.windowSpanBytes(availableBytes: availableBytes, cleanableItems: cleanableItems)
    }

    var body: some View {
        Group {
            if reduceMotion {
                // 减少动态效果：静止渲染一帧，不做波浪/水流动画
                Canvas { context, size in
                    render(context: &context, size: size, phase: 0, animate: false)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        render(context: &context, size: size, phase: phase, animate: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func render(context: inout GraphicsContext, size: CGSize, phase: Double, animate: Bool) {
        let dark = colorScheme == .dark
        let tankRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let tankPath = Path(tankRect)
        let span = Double(max(windowSpanBytes, 1))
        let used = Double(max(0, totalBytes - availableBytes))
        // 标尺顶部留出空间（徽标不顶到窗口圆角）
        let topInset: CGFloat = 26
        let usableH = max(1, size.height - topInset)

        // 已用空间越大，越靠近窗口顶部（池顶）；窗口显示 [total-span, total] 这一段
        func yForUsed(_ value: Double) -> CGFloat {
            let fraction = (Double(totalBytes) - value) / span
            return topInset + CGFloat(min(max(fraction, 0), 1)) * usableH
        }

        let surfaceY = yForUsed(used)
        let waterlineY = yForUsed(Double(max(0, totalBytes - waterlineBytes)))
        let (layers, nonCleanable, trashBytes) = PoolLayers.make(
            items: cleanableItems,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            estimatedRecipeIDs: estimatedRecipeIDs,
            excludedItemIDs: excludedItemIDs
        )

        // 全程只设置一次裁剪
        context.clip(to: tankPath)

        // 1) 天空（空气 = 可用空间）：柔和渐变 + 左上日光
        context.fill(
            tankPath,
            with: .linearGradient(
                Gradient(colors: dark
                    ? [Color(red: 0.06, green: 0.10, blue: 0.16), Color(red: 0.13, green: 0.19, blue: 0.25)]
                    : [Color(red: 0.81, green: 0.90, blue: 0.97), Color(red: 0.94, green: 0.975, blue: 0.96)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        let glowRadius: CGFloat = 260
        context.fill(
            Path(ellipseIn: CGRect(x: -120, y: -160, width: glowRadius * 2, height: glowRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(dark ? 0.09 : 0.26), .clear]),
                center: CGPoint(x: -120 + glowRadius, y: -160 + glowRadius),
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        // 2) E 字型国际水位标尺（预生成位图，水层之下；红区 = 水线以上警戒）
        if let gaugeImage {
            context.draw(gaugeImage, in: tankRect)
        }

        // 3.5) 金属拐角水管（参照 xingyu.wang 官网 pipes：管身金属渐变+高光阴影、两端端盖、拐角连接件）
        let pipeDiameter: CGFloat = 18
        // 进水管数量：每 4 个可清理项对应 1 根，最多 2 根
        let cleanableCount = cleanableItems.filter { $0.recipeID != "trash" && $0.reclaimableBytes > 0 }.count
        let pipeCount = min(2, max(1, (cleanableCount + 3) / 4))
        let pipes: [(xStart: CGFloat, yTop: CGFloat, xElbow: CGFloat, verticalLen: CGFloat)]
        switch pipeCount {
        case 1:
            pipes = [(390, 120, 160, 180)]
        default:
            pipes = [
                (390, 100, 140, 200),
                (390, 200, 270, 100),
            ]
        }
        for (index, pipe) in pipes.enumerated() {
            let name: String
            if index < inflowLabels.count {
                name = inflowLabels[index].0
            } else {
                name = Localized.string("pool.inflow")
            }

            // 进水管自适应：正常情况下水平段固定在 yTop、竖直下口对准水位线；
            // 当水位线升到管顶之上时，整根管上移，保持竖直段至少 minVerticalLen，
            // 管口始终对准水位线，避免进水口被压缩成水下短桩。
            let minVerticalLen: CGFloat = 24
            let pipeTopMin: CGFloat = 40
            let pipeTopY: CGFloat
            let pipeEndY: CGFloat
            if waterlineY >= pipe.yTop + minVerticalLen {
                pipeTopY = pipe.yTop
                pipeEndY = waterlineY
            } else {
                pipeEndY = max(waterlineY, pipeTopMin)
                pipeTopY = max(pipeTopMin, pipeEndY - minVerticalLen)
            }

            // 水平管段（右侧 → 左侧）
            let hRect = CGRect(
                x: pipe.xElbow,
                y: pipeTopY - pipeDiameter / 2,
                width: pipe.xStart - pipe.xElbow,
                height: pipeDiameter
            )
            fillPipe(context: &context, rect: hRect, vertical: false)

            // 垂直管段：下口与水线平齐（自适应后保持最小可见管长）
            let vRect = CGRect(
                x: pipe.xElbow - pipeDiameter / 2,
                y: pipeTopY - pipeDiameter / 2,
                width: pipeDiameter,
                height: pipeEndY - (pipeTopY - pipeDiameter / 2)
            )
            fillPipe(context: &context, rect: vRect, vertical: true)

            // 右端端盖（图例侧）
            fillCap(
                context: &context,
                rect: CGRect(
                    x: pipe.xStart - 6,
                    y: pipeTopY - (pipeDiameter + 8) / 2,
                    width: 6,
                    height: pipeDiameter + 8
                ),
                vertical: true
            )

            // 下端开口端盖（半空出水口）
            fillCap(
                context: &context,
                rect: CGRect(
                    x: pipe.xElbow - (pipeDiameter + 8) / 2,
                    y: pipeEndY - 3,
                    width: pipeDiameter + 8,
                    height: 6
                ),
                vertical: false
            )

            // 拐角连接件（银质）
            drawJoint(
                context: &context,
                center: CGPoint(x: pipe.xElbow, y: pipeTopY),
                size: pipeDiameter + 10
            )

            // 单一标签：项目名称贴在水平管身上（增速标签已按设计移除）
            let midX = (pipe.xStart + pipe.xElbow) / 2
            drawBadge(
                context: &context,
                text: name,
                center: CGPoint(x: midX, y: pipeTopY)
            )

            // 实心水流：直带略微收窄（不圆角），从半空管口流出进入水池 + 落水溅波
            let streamX = pipe.xElbow
            let streamTop = pipeEndY + 3
            let streamBottom = surfaceY
            if animate && streamBottom > streamTop + 4 {
                var band = Path()
                band.move(to: CGPoint(x: streamX - 3.5, y: streamTop))
                band.addLine(to: CGPoint(x: streamX + 3.5, y: streamTop))
                band.addLine(to: CGPoint(x: streamX + 5, y: streamBottom))
                band.addLine(to: CGPoint(x: streamX - 5, y: streamBottom))
                band.closeSubpath()
                context.fill(
                    band,
                    with: .linearGradient(
                        Gradient(colors: [Color.blue.opacity(0.65), Color.blue.opacity(0.35)]),
                        startPoint: CGPoint(x: 0, y: streamTop),
                        endPoint: CGPoint(x: 0, y: streamBottom)
                    )
                )
                // 流动亮线（水平细线，向下移动，不做圆角）
                let flowT = (phase * 0.7).truncatingRemainder(dividingBy: 1)
                let lineY = streamTop + CGFloat(flowT) * (streamBottom - streamTop)
                context.fill(
                    Path(CGRect(x: streamX - 3.5, y: lineY - 1, width: 7, height: 2)),
                    with: .color(.white.opacity(0.35))
                )

                for k in 0..<3 {
                    let t = (phase * 1.1 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let side: CGFloat = k == 1 ? -1 : 1
                    let dx = CGFloat(t) * 14 * side * (1 - t)
                    let dy = -CGFloat(t) * 10 * (1 - t)
                    context.fill(
                        Path(ellipseIn: CGRect(x: streamX + dx - 1.5, y: surfaceY + dy - 1.5, width: 3, height: 3)),
                        with: .color(Color.blue.opacity(0.8 * (1 - t)))
                    )
                }

                let rippleT = (phase * 0.8).truncatingRemainder(dividingBy: 1)
                let rippleRadius = CGFloat(rippleT) * 12
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: streamX - rippleRadius,
                        y: surfaceY - rippleRadius * 0.35,
                        width: rippleRadius * 2,
                        height: rippleRadius * 0.7
                    )),
                    with: .color(Color.blue.opacity(0.7 * (1 - rippleT))),
                    lineWidth: 1.5
                )
            }
        }

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
                    Gradient(colors: dark
                        ? [
                            Color(red: 0.01, green: 0.06, blue: 0.10).opacity(0.66),
                            Color(red: 0.06, green: 0.18, blue: 0.24).opacity(0.50),
                            Color(red: 0.32, green: 0.58, blue: 0.64).opacity(0.26),
                        ]
                        : [
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
            color: dark
                ? Color(red: 0.16, green: 0.24, blue: 0.52).opacity(0.9)
                : PoolLayers.nonCleanableColor.opacity(0.9)
        )
        bottomUsed = nonCleanableTop
        // 废纸篓层（浅蓝，位于不可清理之上、可清理层之下）
        if trashBytes > 0 {
            let top = bottomUsed + Double(trashBytes)
            boundaries.append(yForUsed(top))
            fillLayer(
                context: &context,
                bottomUsed: bottomUsed,
                topUsed: top,
                yForUsed: yForUsed,
                color: PoolLayers.trashColor.opacity(0.85)
            )
            bottomUsed = top
        }
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

        // 6) 水面波纹动效（水的最上层；减少动效时静止为一条直线）
        if animate {
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
        } else {
            var still = Path()
            still.move(to: CGPoint(x: 0, y: surfaceY))
            still.addLine(to: CGPoint(x: size.width, y: surfaceY))
            context.stroke(still, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }

        // 7) 右下角指标面板：放在不可清理深蓝色区域内
        let nonCleanableTopY = yForUsed(Double(nonCleanable))
        let nonCleanableBottomY = yForUsed(0)
        let metricsPanelTop = min(
            max((nonCleanableTopY + nonCleanableBottomY) / 2 - 62, nonCleanableTopY + 8),
            nonCleanableBottomY - 132
        )
        let metricsPanelRect = CGRect(
            x: 232,
            y: metricsPanelTop,
            width: 150,
            height: 124
        )
        drawPoolMetrics(
            context: &context,
            panelRect: metricsPanelRect,
            cleanableBytes: layers.reduce(Int64(0)) { $0 + $1.bytes },
            dark: dark
        )

        // 水池外框（可见窗口的边界）
        context.stroke(
            tankPath,
            with: .color(dark ? Color.white.opacity(0.16) : Color.secondary.opacity(0.5)),
            lineWidth: 1
        )
    }

    /// 画布内直接绘制文本（可选锚点）
    private func drawText(
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

    /// 右下角指标面板：进水管向左上移动后，在 L 型右下角留出的空间展示三个关键数据。
    private func drawPoolMetrics(
        context: inout GraphicsContext,
        panelRect: CGRect,
        cleanableBytes: Int64,
        dark: Bool
    ) {
        let labelColor = dark ? Color.white.opacity(0.65) : Color(red: 0.25, green: 0.36, blue: 0.44)
        let valueColor = dark ? Color.white : Color(red: 0.07, green: 0.17, blue: 0.24)
        let cleanableColor = dark
            ? Color(red: 0.45, green: 0.85, blue: 0.62)
            : Color(red: 0.08, green: 0.50, blue: 0.28)

        let panelPath = Path(roundedRect: panelRect, cornerRadius: 10)
        context.fill(
            panelPath,
            with: .color(dark ? Color.black.opacity(0.62) : Color.white.opacity(0.82))
        )
        context.stroke(
            panelPath,
            with: .color(dark ? Color.white.opacity(0.18) : Color.secondary.opacity(0.4)),
            lineWidth: 1
        )

        let distance = availableBytes - waterlineBytes
        let distanceColor: Color
        if distance >= 0 {
            distanceColor = dark
                ? Color.orange
                : Color(red: 0.75, green: 0.28, blue: 0.12)
        } else {
            distanceColor = dark
                ? Color(red: 0.45, green: 0.85, blue: 0.62)
                : Color(red: 0.08, green: 0.50, blue: 0.28)
        }
        let distanceText = Format.signedBytes(distance)

        let items: [(label: String, value: String, color: Color)] = [
            (Localized.string("pool.available_label"), Format.bytes(availableBytes), valueColor),
            (Localized.string("pool.cleanable_label"), Format.bytes(cleanableBytes), cleanableColor),
            (Localized.string("pool.waterline_distance_label"), distanceText, distanceColor),
        ]
        let rowHeight: CGFloat = 36
        let firstRowY = panelRect.minY + 20
        for (index, item) in items.enumerated() {
            let rowY = firstRowY + CGFloat(index) * rowHeight
            drawText(
                context: &context, text: item.label,
                at: CGPoint(x: panelRect.minX + 12, y: rowY - 10),
                color: labelColor,
                size: 9,
                weight: .medium,
                anchor: .leading
            )
            drawText(
                context: &context, text: item.value,
                at: CGPoint(x: panelRect.minX + 12, y: rowY + 7),
                color: item.color,
                size: 14,
                weight: .semibold,
                anchor: .leading
            )
        }
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

    /// 官网风格金属管身：金属渐变 + 顶部高光/底部阴影（vertical = 管段竖直，渐变沿水平方向）
    private func fillPipe(context: inout GraphicsContext, rect: CGRect, vertical: Bool) {
        let metal = Gradient(colors: [
            Color(white: 0.69), Color(white: 0.78), Color(white: 0.63),
            Color(white: 0.72), Color(white: 0.56), Color(white: 0.66), Color(white: 0.50),
        ])
        let spec = Gradient(stops: [
            .init(color: .white.opacity(0.18), location: 0),
            .init(color: .clear, location: 0.30),
            .init(color: .clear, location: 0.55),
            .init(color: .black.opacity(0.25), location: 0.66),
            .init(color: .black.opacity(0.45), location: 1),
        ])
        let path = Path(rect)
        if vertical {
            context.fill(
                path,
                with: .linearGradient(metal, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0))
            )
            context.fill(
                path,
                with: .linearGradient(spec, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0))
            )
        } else {
            context.fill(
                path,
                with: .linearGradient(metal, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
            )
            context.fill(
                path,
                with: .linearGradient(spec, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
            )
        }
    }

    /// 端盖：金属渐变 + 左上径向高光
    private func fillCap(context: inout GraphicsContext, rect: CGRect, vertical: Bool) {
        let path = Path(roundedRect: rect, cornerRadius: 1)
        let stops = Gradient(colors: [
            Color(white: 0.78), Color(white: 0.63), Color(white: 0.50), Color(white: 0.60),
        ])
        if vertical {
            context.fill(
                path,
                with: .linearGradient(stops, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0))
            )
        } else {
            context.fill(
                path,
                with: .linearGradient(stops, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY))
            )
        }
        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.22), .clear]),
                center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.25),
                startRadius: 0,
                endRadius: max(rect.width, rect.height) * 0.7
            )
        )
    }

    /// 拐角连接件：银质圆角块 + 左上径向高光
    private func drawJoint(context: inout GraphicsContext, center: CGPoint, size: CGFloat) {
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        // 左上角 50% 大圆角，其余角直角
        let radius = size / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        let metal = Gradient(colors: [
            Color(white: 0.75), Color(white: 0.63), Color(white: 0.53),
            Color(white: 0.66), Color(white: 0.50), Color(white: 0.60),
        ])
        context.fill(
            path,
            with: .linearGradient(
                metal,
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )
        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.25), .clear]),
                center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.25),
                startRadius: 0,
                endRadius: size * 0.8
            )
        )
        context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1)
    }

    private func drawBadge(context: inout GraphicsContext, text: String, center: CGPoint) {
        PipePainter.drawLabel(context: &context, text: text, center: center)
    }
}
