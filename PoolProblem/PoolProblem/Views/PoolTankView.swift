import SwiftUI

struct PoolTankView: View {
    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let topInflows: [(name: String, bytes: Int64)]
    let weeklyCleanedBytes: Int64

    private var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - availableBytes) / Double(totalBytes) : 0
    }

    private var waterlineFraction: Double {
        totalBytes > 0 ? Double(totalBytes - waterlineBytes) / Double(totalBytes) : 0
    }

    private var belowWaterline: Bool {
        availableBytes < waterlineBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            inletPipes
            HStack(alignment: .top, spacing: 8) {
                ruler
                tank
            }
            outletPipe
        }
    }

    private var tank: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let waterHeight = height * min(max(usedFraction, 0), 1)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                Rectangle()
                    .fill(waterColor.gradient)
                    .frame(height: waterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Rectangle()
                    .fill(waterlineColor)
                    .frame(height: 2)
                    .offset(y: -height * waterlineFraction + 1)
                Text("水线 \(Format.bytes(waterlineBytes))")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(y: -height * waterlineFraction + 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 210)
    }

    private var ruler: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach([1.0, 0.75, 0.5, 0.25, 0.0], id: \.self) { fraction in
                HStack(spacing: 3) {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 10, height: 1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: 52)
            }
        }
        .padding(.top, 2)
    }

    private var inletPipes: some View {
        HStack(spacing: 14) {
            ForEach(Array(topInflows.prefix(2).enumerated()), id: \.offset) { _, inflow in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue.opacity(0.6))
                        .frame(width: 26, height: 6)
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                    Text("\(inflow.name) \(Format.bytes(inflow.bytes))")
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            if topInflows.isEmpty {
                Text("本周暂无显著增长来源")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var outletPipe: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .font(.caption2)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.green.opacity(0.6))
                .frame(width: 26, height: 6)
            Text("出水（清理）\(Format.bytes(weeklyCleanedBytes))/周")
                .font(.caption2)
        }
    }

    private var waterColor: Color {
        belowWaterline ? .red : .blue
    }

    private var waterlineColor: Color {
        belowWaterline ? .red : .orange
    }
}
