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
                text: Localized.string("outlet.drain"),
                center: CGPoint(x: pipeRect.midX, y: 18)
            )

            // 管子右侧：本周已清理数据
            let dataText = weeklyCleanedBytes > 0
                ? Localized.string("outlet.cleaned_this_week", Format.bytes(weeklyCleanedBytes))
                : Localized.string("outlet.not_cleaned")
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
        PipePainter.drawLabel(context: &context, text: text, center: center, anchorLeading: anchorLeading)
    }
}
