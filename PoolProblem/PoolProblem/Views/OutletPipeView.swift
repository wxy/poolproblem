import SwiftUI

/// 出水管：跨在水池右缘，代表"排水/清理"；上方是点击提示，右侧是本周已清理数据
struct OutletPipeView: View {
    let weeklyCleanedBytes: Int64

    var body: some View {
        Canvas { context, size in
            let pipeRect = CGRect(
                x: 108,
                y: size.height / 2 - 9,
                width: 74,
                height: 18
            )
            PipePainter.fillPipe(context: &context, rect: pipeRect, vertical: false)
            // 左端端盖：左缘对齐水池右缘边线的右边界（边线宽 2pt，线右缘在窗口 x=392 → 画布 x=102）
            PipePainter.fillCap(
                context: &context,
                rect: CGRect(x: 102, y: pipeRect.midY - 13, width: 6, height: 26),
                vertical: true
            )
            PipePainter.fillCap(
                context: &context,
                rect: CGRect(x: 176, y: pipeRect.midY - 13, width: 6, height: 26),
                vertical: true
            )

            // 管子上方：点击提示
            drawPill(
                context: &context,
                text: "排水",
                center: CGPoint(x: pipeRect.midX, y: 18)
            )

            // 管子右侧：本周已清理数据
            let dataText = weeklyCleanedBytes > 0
                ? "本周已清理 \(Format.bytes(weeklyCleanedBytes))"
                : "本周尚未清理"
            drawPill(
                context: &context,
                text: dataText,
                center: CGPoint(x: pipeRect.maxX + 66, y: pipeRect.midY),
                anchorLeading: true
            )
        }
    }

    private func drawPill(
        context: inout GraphicsContext,
        text: String,
        center: CGPoint,
        anchorLeading: Bool = false
    ) {
        let label = Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.black)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: CGSize(width: 340, height: 20))
        let rect = CGRect(
            x: anchorLeading ? center.x : center.x - (textSize.width + 12) / 2,
            y: center.y - (textSize.height + 4) / 2,
            width: textSize.width + 12,
            height: textSize.height + 4
        )
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.85)))
        context.draw(
            resolved,
            at: CGPoint(x: anchorLeading ? center.x + (textSize.width + 12) / 2 : center.x, y: center.y),
            anchor: .center
        )
    }
}
