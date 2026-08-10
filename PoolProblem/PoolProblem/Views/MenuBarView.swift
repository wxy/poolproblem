import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            section {
                HStack(alignment: .top, spacing: 14) {
                    PoolTankView(
                        totalBytes: state.totalBytes,
                        availableBytes: state.availableBytes,
                        waterlineBytes: state.waterlineBytes,
                        cleanableItems: state.items
                    )
                    .frame(width: 250)
                    legend
                }
            }
            summary
            if state.isScanning {
                ProgressView("扫描中…")
                    .controlSize(.small)
            }
            buttons
        }
        .padding(16)
        .frame(width: 560)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var legend: some View {
        let layers = PoolLayers.make(
            items: state.items,
            totalBytes: state.totalBytes,
            availableBytes: state.availableBytes
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text("可清理层（\(layers.layers.count) 项）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(layers.layers) { layer in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(layer.color)
                                .frame(width: 10, height: 10)
                            Text(layer.name)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.bytes(layer.bytes))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    if layers.nonCleanableBytes > 0 {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(PoolLayers.nonCleanableColor)
                                .frame(width: 10, height: 10)
                            Text("不可清理（其余已用）")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(layers.nonCleanableBytes))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("The Pool Problem")
                .font(.headline)
            Spacer()
            Text(state.lastScanAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            LabeledContent("可用", value: Format.bytes(state.availableBytes))
            LabeledContent("共", value: Format.bytes(state.totalBytes))
            LabeledContent("水线", value: Format.bytes(state.waterlineBytes))
            if let prediction = state.predictionDays {
                LabeledContent("预计", value: predictionText(prediction))
            }
        }
        .font(.caption)
    }

    private func predictionText(_ days: Double) -> String {
        if days > 365 {
            return ">1 年（水位稳定）"
        }
        return "\(Int(days.rounded())) 天后到水线"
    }

    private var buttons: some View {
        HStack {
            Button("智能清理") { runSmartClean() }
                .disabled(state.isScanning)
            Spacer()
            SettingsLink {
                Label("设置…", systemImage: "gearshape")
            }
            Button("退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .alert(
            "确认清理",
            isPresented: $state.showCleanConfirm,
            presenting: state.pendingClean
        ) { outcome in
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task { state.cleanOutcome = await service.smartClean(dryRun: false) }
            }
        } message: { outcome in
            Text("将处理 \(outcome.entries.count) 项，估算释放 \(Format.bytes(outcome.freedBytes))（真实以实测为准）。")
        }
    }

    private func runSmartClean() {
        Task {
            state.pendingClean = await service.smartClean(dryRun: true)
            state.showCleanConfirm = state.pendingClean != nil
        }
    }

}
