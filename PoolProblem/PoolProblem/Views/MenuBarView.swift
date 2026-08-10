import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService
    @State private var showSettings = false

    private var estimatedRecipeIDs: Set<String> {
        Set(RecipeRegistry.builtIn().filter(\.cloneProne).map(\.id))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PoolTankView(
                totalBytes: state.totalBytes,
                availableBytes: state.availableBytes,
                waterlineBytes: state.waterlineBytes,
                cleanableItems: state.items,
                estimatedRecipeIDs: estimatedRecipeIDs,
                inflowLabels: state.topInflows
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                rightPanel
                    .frame(width: 310)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.regularMaterial, in: Rectangle())
            }

            // 水池右缘边线（明确水池边界，出水管接点更清晰）
            Rectangle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .position(x: 391, y: 280)
                .allowsHitTesting(false)

            // 出水管：跨在水池右缘、画在面板之上（从池里往外流水），点击触发智能清理
            OutletPipeView(weeklyCleanedBytes: state.weeklyCleanedBytes)
                .frame(width: 190, height: 90)
                .position(x: 385, y: 515)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: 190, height: 60)
                .position(x: 385, y: 515)
                .onTapGesture { runSmartClean() }
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
                .disabled(state.isScanning)
                .help("点击出水管执行智能清理")

            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Text("设置")
                            .font(.headline)
                        Spacer()
                        Button("完成") { showSettings = false }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .onHover { hovering in
                                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                            }
                    }
                    .padding(12)

                    SettingsView(state: state, service: service)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.regularMaterial)
                .zIndex(10)
            }
        }
        .frame(width: 700, height: 560)
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

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The Pool Problem")
                .font(.headline)
            Text(state.lastScanAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未扫描")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            legend

            Divider()

            summary

            Divider()

            countdown

            Spacer(minLength: 0)

            buttons
        }
        .padding(14)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("可用", value: Format.bytes(state.availableBytes))
            LabeledContent("共", value: Format.bytes(state.totalBytes))
            LabeledContent("水线", value: Format.bytes(state.waterlineBytes))
            if let prediction = state.predictionDays {
                LabeledContent("预计", value: predictionText(prediction))
            }
        }
        .font(.caption)
    }

    private var legend: some View {
        let layers = PoolLayers.make(
            items: state.items,
            totalBytes: state.totalBytes,
            availableBytes: state.availableBytes,
            estimatedRecipeIDs: estimatedRecipeIDs
        )
        return VStack(alignment: .leading, spacing: 5) {
            Text("可清理项（\(layers.layers.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(layers.layers) { layer in
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(layer.color.opacity(0.8))
                        .frame(width: 9, height: 9)
                    Text(layer.name)
                        .lineLimit(1)
                        .font(.caption)
                    if layer.estimated {
                        Text("估算")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(layer.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let rate = state.growthRates[layer.itemID], rate > 0 {
                        Text("+\(Format.bytes(Int64(rate * 7)))/周")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    safetyMark(layer.safety)
                }
            }
            if layers.nonCleanableBytes > 0 {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(PoolLayers.nonCleanableColor)
                        .frame(width: 9, height: 9)
                    Text("不可清理（其余已用）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.bytes(layers.nonCleanableBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var countdown: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            if let days = state.predictionDays {
                if days <= 1 {
                    Text("距自动清理阈值约 \(Int((days * 24).rounded())) 小时")
                } else {
                    Text("距自动清理阈值约 \(Int(days.rounded())) 天")
                }
            } else {
                Text("水位稳定，暂无自动清理计划")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering in
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
            Button("退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering in
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
        }
    }

    private func runSmartClean() {
        // 用最近一次扫描结果即时生成预览（不做全量扫描，避免点击后长时间等待）
        let config = service.loadConfig()
        let evaluator = RuleEvaluator(config: config)
        let suggestions = state.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
            let action = evaluator.evaluate(item: item) { name in
                name.map { PGrepProcessInspector().isRunning($0) } ?? false
            }
            switch action.action {
            case .skip: return nil
            default: return (item, action)
            }
        }
        let outcome = CleanOutcome(
            entries: suggestions.map { entry in
                CleanLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    itemIDs: [entry.0.id],
                    freedBytes: entry.0.reclaimableBytes,
                    disposition: entry.1.action == .trash ? .trash : .deletePermanently
                )
            },
            freedBytes: suggestions.reduce(0) { $0 + $1.0.reclaimableBytes },
            actualFreedBytes: 0,
            stillBelowWaterline: state.availableBytes < state.waterlineBytes
        )
        state.pendingClean = outcome
        state.showCleanConfirm = !outcome.entries.isEmpty
    }

    private func predictionText(_ days: Double) -> String {
        if days > 365 {
            return ">1 年（水位稳定）"
        }
        return "\(Int(days.rounded())) 天后到水线"
    }

    private func safetyMark(_ safety: SafetyLevel) -> some View {
        switch safety {
        case .safeWhileRunning:
            return Text("可清理").font(.caption2).foregroundStyle(.green)
        case .requiresQuit:
            return Text("需退出").font(.caption2).foregroundStyle(.orange)
        case .userConfirm:
            return Text("需确认").font(.caption2).foregroundStyle(.gray)
        }
    }
}
