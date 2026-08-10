import SwiftUI

/// 出水管：跨在水池右缘，代表"排水/清理"；管内水流向右流动
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

            // 标签（管子上方）
            let text = weeklyCleanedBytes > 0
                ? "本周已清理 \(Format.bytes(weeklyCleanedBytes))"
                : "本周尚未清理"
            PipePainter.drawBadge(
                context: &context,
                text: text,
                center: CGPoint(x: pipeRect.midX, y: 18)
            )
        }
    }
}
