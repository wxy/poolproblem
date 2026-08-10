import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PoolTankView(
                totalBytes: state.totalBytes,
                availableBytes: state.availableBytes,
                waterlineBytes: state.waterlineBytes,
                topInflows: state.topInflows,
                weeklyCleanedBytes: state.weeklyCleanedBytes
            )
            summary
            if state.isScanning {
                ProgressView("扫描中…")
                    .controlSize(.small)
            }
            itemList
            buttons
        }
        .padding(16)
        .frame(width: 440)
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
                LabeledContent("预计", value: "\(Int(prediction.rounded())) 天后到水线")
            }
        }
        .font(.caption)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可清理项（共 \(state.items.count) 项）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(state.items.sorted { $0.reclaimableBytes > $1.reclaimableBytes }.prefix(6))) { item in
                        HStack(spacing: 8) {
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.bytes(item.reclaimableBytes))
                                .foregroundStyle(.secondary)
                            badge(for: item.safety)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
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

    private func badge(for safety: SafetyLevel) -> some View {
        let (text, color): (String, Color) = switch safety {
        case .safeWhileRunning: ("可自动清", .green)
        case .requiresQuit: ("需退出", .orange)
        case .userConfirm: ("需确认", .gray)
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
