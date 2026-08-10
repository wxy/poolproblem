import SwiftUI

/// 官网风格水管绘制工具（xingyu.wang pipes 组件同款）
enum PipePainter {
    static func fillPipe(context: inout GraphicsContext, rect: CGRect, vertical: Bool) {
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

    static func fillCap(context: inout GraphicsContext, rect: CGRect, vertical: Bool) {
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

    static func drawBadge(context: inout GraphicsContext, text: String, center: CGPoint) {
        let label = Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: CGSize(width: 160, height: 20))
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
