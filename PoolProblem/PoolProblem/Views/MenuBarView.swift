import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let service: AppService
    @State private var showSettings = false
    @State private var spinning = false
    @State private var showNonCleanableInfo = false

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
            .onHover { _ in NSCursor.arrow.set() }

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
                .frame(width: 380, height: 90)
                .position(x: 480, y: 515)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: 380, height: 60)
                .position(x: 480, y: 515)
                .onTapGesture { runSmartClean() }
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
                .disabled(state.isScanning)
                .help(Localized.string("outlet.click_to_clean"))

            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Text(Localized.string("settings.title"))
                            .font(.headline)
                        Spacer()
                        Button(Localized.string("settings.done")) { showSettings = false }
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
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(12)
            }

            if showNonCleanableInfo {
                infoOverlay(
                    title: Localized.string("section.non_cleanable"),
                    body: Localized.string("info.non_cleanable_body")
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(13)
            }
        }
        .frame(width: 700, height: 560)
        .onHover { hovering in
            if !hovering { NSCursor.arrow.set() }
        }
        .alert(
            Localized.string("clean.confirm_title"),
            isPresented: $state.showCleanConfirm,
            presenting: state.pendingClean
        ) { outcome in
            Button(Localized.string("common.cancel"), role: .cancel) {}
            Button(Localized.string("common.clean"), role: .destructive) {
                // 实际清理：手动模式一律进回收站，可恢复
                Task { state.cleanOutcome = await service.smartClean(dryRun: false) }
            }
        } message: { outcome in
            Text(Localized.string("clean.confirm_message", outcome.entries.count, Format.bytes(outcome.freedBytes)))
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "The Pool Problem")
                        .font(.headline)
                    Text(state.lastScanAt.map { Localized.string("header.updated_at", $0.formatted(date: .omitted, time: .shortened)) } ?? Localized.string("header.not_scanned"))
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
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                statItem(
                    Localized.string("stat.available"),
                    Format.bytes(state.availableBytes),
                    color: state.availableBytes < state.waterlineBytes ? .red : .green
                )
                statItem(Localized.string("stat.used"), Format.bytes(state.totalBytes - state.availableBytes))
                statItem(Localized.string("stat.total"), Format.bytes(state.totalBytes))
                statItem(Localized.string("stat.waterline"), Format.bytes(state.waterlineBytes))
                statItem(Localized.string("stat.prediction"), state.predictionDays.map { predictionText($0) } ?? "—")
                statItem(
                    Localized.string("stat.weekly_net_change"),
                    Format.bytes(state.weeklyNetChangeBytes),
                    color: state.weeklyNetChangeBytes >= 0 ? .orange : .green
                )
            }
            if !state.availableHistory.isEmpty {
                let history = zip(state.historyTimestamps, state.availableHistory).map { ($0, $1) }
                SpaceChartView(
                    history: history,
                    waterline: state.waterlineBytes,
                    events: state.cleaningEvents
                )
                .frame(height: 60)
                HStack(spacing: 12) {
                    chartDot(.orange, Localized.string("chart.manual"))
                    chartDot(.green, Localized.string("chart.auto"))
                    Spacer()
                }
            }
        }
    }

    private func chartDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statItem(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(Localized.string("section.cleanable_count", poolLayers.layers.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(poolLayers.layers) { layer in
                Button {
                    if let item = state.items.first(where: { $0.id == layer.itemID }) {
                        withAnimation { state.detailItem = item }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(layer.color.opacity(0.8))
                            .frame(width: 9, height: 9)
                        Text(Localized.recipeName(layer.recipeID, fallback: layer.name))
                            .lineLimit(1)
                            .strikethrough(state.cleanedItemIDs.contains(layer.itemID))
                            .foregroundStyle(state.cleanedItemIDs.contains(layer.itemID) ? Color.secondary : Color.primary)
                            .font(.caption)
                        if let rate = state.growthRates[layer.itemID], rate > 0 {
                            let weekly = rate * 7
                            let arrows = weekly < 0.5e9 ? 1 : (weekly < 2e9 ? 2 : 3)
                            Text(String(repeating: "↑", count: arrows))
                                .font(.caption2)
                                .foregroundStyle(arrows == 1 ? Color.green : (arrows == 2 ? Color.orange : Color.red))
                        }
                        Spacer()
                        Text(Format.bytes(layer.bytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // COW 项：大小后面显示"?"（占位对齐，非 COW 项保留空白）
                        Text(verbatim: layer.estimated ? "?" : " ")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(width: 10)
                        safetyMark(layer)
                    }
                    .opacity(state.deletingItemID == layer.itemID ? 0.35 : 1)
                    .animation(
                        state.deletingItemID == layer.itemID
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                        value: state.deletingItemID == layer.itemID
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    withAnimation { state.trashExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(PoolLayers.trashColor)
                            .frame(width: 9, height: 9)
                        Text(Localized.string("recipe.trash"))
                            .font(.caption)
                        Spacer()
                        Text(Format.bytes(poolLayers.trashBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Localized.string("badge.manual"))
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
                                Text(verbatim: "· \(name)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if state.trashOthersBytes > 0 {
                            Text(Localized.string("trash.others", Format.bytes(state.trashOthersBytes)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 14)
                }
                if poolLayers.nonCleanableBytes > 0 {
                    Button {
                        withAnimation { showNonCleanableInfo = true }
                    } label: {
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(PoolLayers.nonCleanableColor)
                                .frame(width: 9, height: 9)
                            Text(Localized.string("section.non_cleanable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(poolLayers.nonCleanableBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var countdown: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            if let days = state.predictionDays {
                if days <= 1 {
                    Text(Localized.string("countdown.hours", Int((days * 24).rounded())))
                } else {
                    Text(Localized.string("countdown.days", Int(days.rounded())))
                }
            } else {
                Text(Localized.string("countdown.stable"))
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
            .help(Localized.string("refresh.tooltip"))
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
            .help(Localized.string("quit.tooltip"))
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
                Text(Localized.recipeName(item.recipeID, fallback: item.name))
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
                Text(Localized.string("detail.cow_warning"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack(spacing: 6) {
                Text(Localized.string("detail.path"))
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
                LabeledContent(Localized.string("detail.reclaimable"), value: Format.bytes(item.reclaimableBytes))
                LabeledContent(Localized.string("detail.safety"), value: safetyText(item.safety))
            }
            .font(.caption)
            if let rate = state.growthRates[item.id], rate > 0 {
                LabeledContent(Localized.string("detail.weekly_rate"), value: "+\(Format.bytes(Int64(rate * 7)))")
                    .font(.caption)
            }

            HStack(spacing: 10) {
                if isKept {
                    Button(Localized.string("detail.unkeep")) {
                        service.unkeepItem(item.id)
                    }
                } else {
                    Button(Localized.string("detail.keep")) {
                        service.keepItem(item)
                    }
                }
                Spacer()
                Button(Localized.string("common.close")) {
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

    /// 通用信息浮层（不可清理说明等）
    private func infoOverlay(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation { showNonCleanableInfo = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(Localized.string("common.close")) {
                    withAnimation { showNonCleanableInfo = false }
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
            return Localized.string("explain.xcode")
        case .simulator:
            return Localized.string("explain.simulator")
        case .packageManager:
            return Localized.string("explain.package_manager")
        case .common:
            return Localized.string("explain.common")
        case .project, .custom:
            return Localized.string("explain.project")
        }
    }

    private func safetyText(_ safety: SafetyLevel) -> String {
        switch safety {
        case .safeWhileRunning:
            return Localized.string("safety.safe_while_running")
        case .requiresQuit:
            return Localized.string("safety.requires_quit")
        case .userConfirm:
            return Localized.string("safety.user_confirm")
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func predictionText(_ days: Double) -> String {
        if days > 365 {
            return Localized.string("prediction.stable")
        }
        return Localized.string("prediction.days", Int(days.rounded()))
    }

    private func safetyMark(_ layer: CleanableLayer) -> some View {
        if state.keptItemIDs.contains(layer.itemID) {
            return Text(Localized.string("badge.kept")).font(.caption2).foregroundStyle(.orange)
        }
        if layer.recipeID == "trash" {
            return Text(Localized.string("badge.manual")).font(.caption2).foregroundStyle(.blue)
        }
        let safety = layer.safety
        switch safety {
        case .safeWhileRunning:
            return Text(Localized.string("badge.cleanable")).font(.caption2).foregroundStyle(.green)
        case .requiresQuit:
            return Text(Localized.string("badge.requires_quit")).font(.caption2).foregroundStyle(.red)
        case .userConfirm:
            return Text(Localized.string("badge.user_confirm")).font(.caption2).foregroundStyle(.gray)
        }
    }
}
