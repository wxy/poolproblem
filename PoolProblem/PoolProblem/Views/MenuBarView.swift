import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let prediction = state.predictionDays {
                Text("按当前流速，约 \(Int(prediction.rounded())) 天后到水线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.isScanning {
                ProgressView("扫描中…")
                    .controlSize(.small)
            }
            itemList
            buttons
        }
        .padding(12)
        .frame(width: 340)
        .task { service.start() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("可用 \(Format.bytes(state.availableBytes))")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("共 \(Format.bytes(state.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .tint(state.availableBytes < 20_000_000_000 ? .red : .blue)
                .frame(width: 80)
        }
    }

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(state.items.sorted { $0.reclaimableBytes > $1.reclaimableBytes }) { item in
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
        .frame(maxHeight: 220)
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

    private var fraction: Double {
        state.totalBytes > 0 ? Double(state.availableBytes) / Double(state.totalBytes) : 0
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
