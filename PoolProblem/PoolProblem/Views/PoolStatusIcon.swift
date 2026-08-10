import AppKit

/// 菜单栏模板图标：蓄水池截面，水位随"已用空间"比例变化
enum PoolStatusIcon {
    static func image(usedRatio: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = true
        image.lockFocus()
        defer { image.unlockFocus() }

        let ratio = CGFloat(min(max(usedRatio, 0), 1))
        let rect = NSRect(x: 2.5, y: 3.5, width: 13, height: 11)
        let body = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)

        // 池壁
        NSColor.black.setStroke()
        body.lineWidth = 1.2
        body.stroke()

        // 水体（从底部起，占 usedRatio；上沿画一道小水波）
        let waterHeight = rect.height * ratio
        if waterHeight > 0.5 {
            let waterRect = NSRect(x: rect.minX + 1, y: rect.minY, width: rect.width - 2, height: waterHeight)
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(rect: waterRect).fill()

            // 水面波浪线
            let surfaceY = rect.minY + waterHeight
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: rect.minX + 1, y: surfaceY))
            var x: CGFloat = rect.minX + 1
            var up = true
            while x < rect.maxX - 2 {
                let next = min(x + 3, rect.maxX - 2)
                wave.line(to: NSPoint(x: next, y: surfaceY + (up ? 0.9 : -0.9)))
                up.toggle()
                x = next
            }
            wave.line(to: NSPoint(x: rect.maxX - 1, y: surfaceY))
            NSColor.black.setStroke()
            wave.lineWidth = 1
            wave.stroke()
        }
        return image
    }
}
