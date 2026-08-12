import AppKit

/// 菜单栏模板图标：玻璃蓄水池（18pt，自动 2x backing）
/// 水位语义（方案 B）：可用空间 ≥ 安全上限（默认 2× 水位线）→ 空缸；
/// 可用空间 ≤ 水位线 → 满缸；两者之间线性过渡。
enum PoolStatusIcon {
    static func image(availableBytes: Int64, waterlineBytes: Int64) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            draw(level: level(availableBytes: availableBytes, waterlineBytes: waterlineBytes), ctx: ctx)
        }
        image.unlockFocus()
        return image
    }

    /// 方案 B 映射：可用空间在 [水位线, 2×水位线] 之间时，水位 1→0
    private static func level(availableBytes: Int64, waterlineBytes: Int64) -> Double {
        let waterline = Double(max(waterlineBytes, 0))
        let ceiling = max(waterline * 2, 1)
        let available = Double(max(availableBytes, 0))
        if available >= ceiling { return 0 }
        if available <= waterline { return 1 }
        return (ceiling - available) / (ceiling - waterline)
    }

    /// 在 18pt 坐标系内绘制；几何对齐整数像素网格，统一 1pt 描边
    private static func draw(level: Double, ctx: CGContext) {
        let ratio = CGFloat(min(max(level, 0), 1))
        let rect = CGRect(x: 3, y: 4, width: 12, height: 10)
        let radius: CGFloat = 1.5

        // 缸体轮廓：上缘平直且不封口（U 形），底部小圆角
        let walls = CGMutablePath()
        walls.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        walls.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        walls.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                           control: CGPoint(x: rect.minX, y: rect.minY))
        walls.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        walls.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
        walls.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        // 闭合缸体（含顶线）用于裁剪水体
        guard let tankClosed = walls.mutableCopy() else { return }
        tankClosed.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        tankClosed.closeSubpath()

        // 水体：铺满缸内（贴壁），底部起随 ratio 升降
        let waterHeight = rect.height * ratio
        if waterHeight > 0.5 {
            ctx.saveGState()
            ctx.addPath(tankClosed)
            ctx.clip()
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.85))
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: waterHeight))
            ctx.restoreGState()
        }

        // 缸壁描边（画在水之上，水与壁自然相接）
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        ctx.addPath(walls)
        ctx.strokePath()

        // 标准波纹水面线：三段规整正弦（满幅均匀分布）
        if waterHeight > 0.5 {
            let surfaceY = rect.minY + waterHeight
            let x0 = rect.minX + 1.3
            let x1 = rect.maxX - 1.3
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x0, y: surfaceY))
            var x: CGFloat = x0
            while x <= x1 {
                let t = (x - x0) / (x1 - x0)
                // 相位 -π/2：三个波峰落在 1/6、1/2、5/6，整组波纹居中
                let y = surfaceY + sin(t * .pi * 6 - .pi / 2) * 0.6
                ctx.addLine(to: CGPoint(x: x, y: y))
                x += 0.4
            }
            ctx.strokePath()
        }
    }
}
