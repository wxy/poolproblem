import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService
    @State private var showSettings = false
    @State private var spinning = false

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
                inflowLabels: state.topInflows,
                excludedItemIDs: state.cleanedItemIDs
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

            if let item = state.detailItem {
                detailOverlay(item)
                    .zIndex(12)
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
                // 实际清理：手动模式一律进回收站，可恢复
                Task { state.cleanOutcome = await service.smartClean(dryRun: false) }
            }
        } message: { outcome in
            Text("将处理 \(outcome.entries.count) 项，估算释放 \(Format.bytes(outcome.freedBytes))（将移入回收站，可恢复；真实以实测为准）。")
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The Pool Problem")
                        .font(.headline)
                    Text(state.lastScanAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未扫描")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                iconButtons
            }

            Divider()

            legend

            Divider()

            summary

            Divider()

            countdown

            if let summary = state.lastCleanSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        let poolLayers = PoolLayers.make(
            items: state.items,
            totalBytes: state.totalBytes,
            availableBytes: state.availableBytes,
            estimatedRecipeIDs: estimatedRecipeIDs,
            excludedItemIDs: []   // 图例保留已清理行（打删除线），只有水池层消失
        )
        return VStack(alignment: .leading, spacing: 5) {
            Text("可清理项（\(poolLayers.layers.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(poolLayers.layers) { layer in
                Button {
                    if let item = state.items.first(where: { $0.id == layer.itemID }) {
                        state.detailItem = item
                    }
                } label: {
                    HStack(spacing: 5) {
                        if state.deletingItemID == layer.itemID {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 9, height: 9)
                        }
                        Rectangle()
                            .fill(layer.color.opacity(0.8))
                            .frame(width: 9, height: 9)
                        Text(layer.name)
                            .lineLimit(1)
                            .strikethrough(state.cleanedItemIDs.contains(layer.itemID))
                            .foregroundStyle(state.cleanedItemIDs.contains(layer.itemID) ? Color.secondary : Color.primary)
                            .font(.caption)
                        if layer.estimated {
                            Text("可能虚高")
                                .font(.caption2)
                                .foregroundStyle(.orange)
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
                        safetyMark(layer)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
            }

            if poolLayers.trashBytes > 0 || poolLayers.nonCleanableBytes > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if poolLayers.trashBytes > 0 {
                        Button {
                            withAnimation { state.trashExpanded.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Rectangle()
                                    .fill(PoolLayers.trashColor)
                                    .frame(width: 9, height: 9)
                                Text("废纸篓")
                                    .font(.caption)
                                Spacer()
                                Text(Format.bytes(poolLayers.trashBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("需手动")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Image(systemName: state.trashExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .onHover { hovering in
                            hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                        }
                        if state.trashExpanded {
                            VStack(alignment: .leading, spacing: 3) {
                                if !state.ourTrashNames.isEmpty {
                                    ForEach(state.ourTrashNames, id: \.self) { name in
                                        Text("· \(name)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if state.trashOthersBytes > 0 {
                                    Text("其他（手动放入）：\(Format.bytes(state.trashOthersBytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 14)
                        }
                    }
                    if poolLayers.nonCleanableBytes > 0 {
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(PoolLayers.nonCleanableColor)
                                .frame(width: 9, height: 9)
                            Text("不可清理（其余已用）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(poolLayers.nonCleanableBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
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

    /// 右上角图标：刷新、设置、退出
    private var iconButtons: some View {
        HStack {
            Button {
                Task { await service.scanNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: spinning
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering in
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
            .help("手动刷新")
            .disabled(state.isScanning)
            .onChange(of: state.isScanning) { _, scanning in
                spinning = scanning
            }
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
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering in
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
            .help("退出")
        }
    }

    private func runSmartClean() {
        // 用最近一次扫描结果即时生成预览（不做全量扫描，避免点击后长时间等待）
        let config = service.loadConfig()
        let evaluator = RuleEvaluator(config: config)
        let suggestions = state.items
            .filter { $0.reclaimableBytes > 0 }
            .compactMap { item -> (ScanItem, EvaluatedAction)? in
            let action = evaluator.evaluate(
                item: item,
                isProcessRunning: { name in
                    name.map { PGrepProcessInspector().isRunning($0) } ?? false
                },
                force: true
            )
            switch action.action {
            case .trash, .delete:
                return (item, action)
            default:
                return nil
            }
        }
        let outcome = CleanOutcome(
            entries: suggestions.map { entry in
                CleanLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    itemIDs: [entry.0.id],
                    freedBytes: entry.0.reclaimableBytes,
                    disposition: .trash
                )
            },
            freedBytes: suggestions.reduce(0) { $0 + $1.0.reclaimableBytes },
            actualFreedBytes: 0,
            stillBelowWaterline: state.availableBytes < state.waterlineBytes
        )
        state.pendingClean = outcome
        state.showCleanConfirm = !outcome.entries.isEmpty
    }

    /// 点击可清理项后弹出的说明浮层
    private func detailOverlay(_ item: ScanItem) -> some View {
        let isKept = state.keptItemIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.name)
                    .font(.headline)
                Spacer()
                Button {
                    state.detailItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Text(explanation(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)

            if estimatedRecipeIDs.contains(item.recipeID) {
                Text("提示：此项是 APFS 克隆（COW）文件，表观大小可能虚高，清理后实际释放的空间可能远小于显示值。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack(spacing: 6) {
                Text("路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    revealInFinder(item.path)
                } label: {
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 16) {
                LabeledContent("可清理量", value: Format.bytes(item.reclaimableBytes))
                LabeledContent("安全级", value: safetyText(item.safety))
            }
            .font(.caption)

            HStack(spacing: 10) {
                if isKept {
                    Button("取消保留") {
                        service.unkeepItem(item.id)
                    }
                } else {
                    Button("保留此项（不再清理）") {
                        service.keepItem(item)
                    }
                }
                Spacer()
                Button("关闭") {
                    state.detailItem = nil
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }

    private func explanation(for item: ScanItem) -> String {
        switch item.category {
        case .xcode:
            return "属于 Xcode 的构建产物或测试快照，删除后会在下次构建/测试时自动重新生成，因此可以安全清理。"
        case .simulator:
            return "模拟器相关设备数据，删除后如需使用会重新创建；清理前请确认对应模拟器已退出。"
        case .packageManager:
            return "包管理器的下载缓存，删除后需要时会重新下载，不影响已安装的依赖。"
        case .common:
            return "应用通用缓存，删除后应用会按需重新生成，不影响你的数据。"
        case .project, .custom:
            return "项目或自定义目录，删除前请确认其中没有需要保留的内容。"
        }
    }

    private func safetyText(_ safety: SafetyLevel) -> String {
        switch safety {
        case .safeWhileRunning:
            return "可自动清理"
        case .requiresQuit:
            return "需退出应用"
        case .userConfirm:
            return "需手动确认"
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func predictionText(_ days: Double) -> String {
        if days > 365 {
            return ">1 年（水位稳定）"
        }
        return "\(Int(days.rounded())) 天后到水线"
    }

    private func safetyMark(_ layer: CleanableLayer) -> some View {
        if state.keptItemIDs.contains(layer.itemID) {
            return Text("已保留").font(.caption2).foregroundStyle(.orange)
        }
        if layer.recipeID == "trash" {
            return Text("需手动").font(.caption2).foregroundStyle(.blue)
        }
        let safety = layer.safety
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
