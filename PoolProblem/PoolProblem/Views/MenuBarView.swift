import SwiftUI
import AppKit
import DiskReservoirCore

struct MenuBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ObservedObject var state: AppState
    let service: AppService
    @State private var showSettings = false
    @State private var spinning = false
    @State private var showNonCleanableInfo = false
    @State private var showCleanHistory = false
    @State private var cleanFailureNotice: String?
    @State private var quitProcessRunning = false

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
                excludedItemIDs: state.cleanedItemIDs,
                gaugeImage: state.poolGaugeImage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                rightPanel
                    .frame(width: 310, height: 470, alignment: .top)
                    .background(
                        Rectangle().fill(
                            Color(nsColor: .windowBackgroundColor)
                        )
                    )
            }

            // 右侧白色面板下方：单独铺一块黑色区域，排水管叠在这块区域上
            Rectangle()
                .fill(Color.black)
                .frame(width: 310, height: 90)
                .position(x: 545, y: 515)
                .allowsHitTesting(false)

            // 水池右缘池壁：内侧受光高光 + 深色壁体（出水管左端盖对齐壁体右缘 x=392）
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.32 : 0.70))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .position(x: 390, y: 280)
            .allowsHitTesting(false)

            // 出水管：跨在水池右缘、画在面板之上（从池里往外流水），点击触发智能清理
            OutletPipeView(weeklyCleanedBytes: state.weeklyCleanedBytes)
                .frame(width: 380, height: 90)
                .position(x: 480, y: 515)
                .allowsHitTesting(false)

            // 点击区只覆盖出水管本身及上方的"排水"标签（窗口坐标约 x 388–488 / y 480–530），
            // 避免整条宽透明层盖住右侧面板文本、让大片非交互区域显示手型。
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 100, height: 50)
                .position(x: 438, y: 505)
                .onTapGesture { runSmartClean() }
                .cursorPointingHand(enabled: !state.isScanning)
                .disabled(state.isScanning)
                .help(Localized.string("outlet.click_to_clean"))

            // 清理完成反馈：出水口处的绿色闪光（水花）
            CleanCelebrationView(celebrationID: state.cleanCelebrationID)
                .frame(width: 380, height: 90)
                .position(x: 480, y: 515)
                .allowsHitTesting(false)

            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Text(Localized.string("settings.title"))
                            .font(.headline)
                        Spacer()
                        Button(Localized.string("settings.done")) {
                            withAnimation(overlaySpring) { showSettings = false }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .focusEffectDisabled()
                        .cursorPointingHand()
                    }
                    .padding(12)

                    SettingsView(state: state, service: service)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.97))
                // 设置面板含 AppKit 原生控件（Slider/SegmentedControl），
                // 缩放过渡会在动画中提出过小宽度导致约束冲突，改用透明度+轻位移
                .transition(.opacity.combined(with: .offset(y: 6)))
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

            if showCleanHistory {
                cleanHistoryOverlay
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(13)
            }

        }
        .frame(width: 700, height: 560)
        .onHover { hovering in
            if !hovering { NSCursor.arrow.set() }
        }
        .onChange(of: state.deletingItemID) { _, newValue in
            if newValue != nil {
                // 删除期间：大小在 1.2 秒内平滑缩到 0，闪动随之停止，行消失
                withAnimation(.easeOut(duration: 1.2)) {
                    state.deletingProgress = 0
                }
            } else {
                state.deletingProgress = 1
            }
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
        VStack(spacing: 0) {
            rightPanelHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    legend

                    Divider()

                    summary

                    Divider()

                    if let summary = state.lastCleanSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !state.autoCleanPlans.isEmpty {
                        autoCleanPlanList
                    } else if !state.autoCleanPlan.isEmpty {
                        Text(state.autoCleanPlan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
    }

    private var autoCleanPlanList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(state.autoCleanPlans) { plan in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plan.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if let estimatedDate = plan.estimatedDate {
                            Text(estimatedTimeText(estimatedDate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(Localized.string("countdown.plan_pending"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.16))
                                .frame(height: 1)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(
                                    width: max(1, geo.size.width * CGFloat(min(max(plan.progress, 0), 1))),
                                    height: 1
                                )
                        }
                    }
                    .frame(height: 1)
                }
            }
        }
    }

    private var rightPanelHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "The Pool Problem")
                    .font(.headline)
                Text(state.isScanning
                     ? Localized.string("refresh.scanning")
                     : (state.lastScanAt.map { Localized.string("header.updated_at", $0.formatted(date: .omitted, time: .shortened)) } ?? Localized.string("header.not_scanned")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            iconButtons
        }
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
            excludedItemIDs: state.cleanedItemIDs
        )
        return VStack(alignment: .leading, spacing: 5) {
            Text(Localized.string("section.cleanable_count", poolLayers.layers.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(poolLayers.layers.filter { layer in
                !(layer.itemID == state.deletingItemID && state.deletingProgress <= 0)
            }) { layer in
                Button {
                    if let item = state.items.first(where: { $0.id == layer.itemID }) {
                        withAnimation(overlaySpring) { state.detailItem = item }
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
                        let deleting = state.deletingItemID == layer.itemID
                        let displayBytes = deleting
                            ? Int64(Double(layer.bytes) * state.deletingProgress)
                            : layer.bytes
                        Text(Format.bytes(displayBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        // COW 项：大小后面显示"?"（占位对齐，非 COW 项保留空白）
                        Text(verbatim: layer.estimated ? "?" : " ")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(width: 10)
                        safetyMark(layer)
                    }
                    .frame(height: 22)
                    .opacity(
                        state.deletingItemID == layer.itemID && state.deletingProgress > 0
                            ? 0.35
                            : 1
                    )
                    .animation(
                        state.deletingItemID == layer.itemID && state.deletingProgress > 0
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                        value: state.deletingItemID == layer.itemID && state.deletingProgress > 0
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .cursorPointingHand()
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
                        Image(systemName: state.trashExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.bytes(poolLayers.trashBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Localized.string("badge.manual"))
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .cursorPointingHand()
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
                        withAnimation(overlaySpring) { showNonCleanableInfo = true }
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
                    .cursorPointingHand()
                }
            }
            .padding(.top, 2)

            // 手动清理项：应用无法删除，只能提示用户到对应应用/Finder 清理
            let manualItems = state.items
                .filter {
                    $0.reclaimableBytes > 0
                        && CleanupRationale.make(for: $0).isManual
                }
                .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
            if !manualItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(Localized.string("section.manual_cleanup"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(manualItems) { item in
                        Button {
                            withAnimation(overlaySpring) { state.detailItem = item }
                        } label: {
                            HStack(spacing: 5) {
                                Rectangle()
                                    .fill(PoolLayers.nonCleanableColor.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                Text(Localized.recipeName(item.recipeID, fallback: item.name))
                                    .lineLimit(1)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(Format.bytes(item.reclaimableBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(Localized.string("badge.manual"))
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                    .help(Localized.string("badge.tooltip.xcode_manual"))
                            }
                            .frame(height: 22)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .cursorPointingHand()
                    }
                }
                .padding(.top, 4)
            }
        }
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
            .buttonStyle(PressableButtonStyle())
            .focusEffectDisabled()
            .cursorPointingHand(enabled: !state.isScanning)
            .help(state.isScanning
                  ? Localized.string("refresh.scanning")
                  : Localized.string("refresh.tooltip"))
            .disabled(state.isScanning)
            .opacity(state.isScanning ? 0.4 : 1)
            .onChange(of: state.isScanning) { _, scanning in
                spinning = scanning
            }
            // 弹窗可能在扫描开始后才打开，onChange 不会触发；出现时同步一次当前状态
            .onAppear {
                spinning = state.isScanning
            }
            Button {
                withAnimation(overlaySpring) { showSettings = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PressableButtonStyle())
            .focusEffectDisabled()
            .cursorPointingHand()
            Button {
                withAnimation(overlaySpring) { showCleanHistory = true }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(PressableButtonStyle())
            .focusEffectDisabled()
            .cursorPointingHand()
            .help(Localized.string("history.tooltip"))
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(PressableButtonStyle())
            .focusEffectDisabled()
            .cursorPointingHand()
            .help(Localized.string("quit.tooltip"))
        }
    }

    private func runSmartClean() {
        // 用最近一次扫描结果即时生成预览（不做全量扫描，避免点击后长时间等待）
        let config = service.loadConfig()
        let evaluator = RuleEvaluator(config: config)
        let suggestions = state.items
            .filter {
                $0.reclaimableBytes > 0
                    && !CleanupRationale.make(for: $0).isManual
            }
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
                    withAnimation(overlaySpring) { state.detailItem = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
                .cursorPointingHand()
            }

            let rationale = CleanupRationale.make(for: item)
            let appCleanable = !rationale.isManual
                && item.cleanability != .displayOnly
            VStack(alignment: .leading, spacing: 4) {
                Text(Localized.string("detail.why_suggested"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Localized.suggestionText(rationale.suggestion))
                    .font(.caption)
                if appCleanable {
                    Text(Localized.string("detail.why_cleanable"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Localized.string("detail.why_cleanable_reason"))
                        .font(.caption)
                }
                if item.safety == .requiresQuit, let appName = processName(for: item) {
                    Text(Localized.string("detail.why_quit"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Localized.string("detail.why_quit_reason", appName))
                        .font(.caption)
                }
                if let confirmation = rationale.confirmation {
                    Text(rationale.isManual
                         ? Localized.string("detail.why_manual")
                         : Localized.string("detail.why_confirm"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Localized.confirmationText(confirmation))
                        .font(.caption)
                }
                Text(Localized.string("detail.last_used"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lastUsedText(rationale.lastUsed))
                    .font(.caption)
            }

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
                .cursorPointingHand()
                Spacer()
            }

            Divider()

            HStack(spacing: 16) {
                LabeledContent(Localized.string("detail.reclaimable"), value: Format.bytes(item.reclaimableBytes))
                LabeledContent(Localized.string("detail.safety"), value: safetyText(for: item))
            }
            .font(.caption)
            if let rate = state.growthRates[item.id], rate > 0 {
                LabeledContent(Localized.string("detail.weekly_rate"), value: "+\(Format.bytes(Int64(rate * 7)))")
                    .font(.caption)
            }

            HStack(spacing: 10) {
                if item.cleanability != .displayOnly,
                          !rationale.isManual,
                          item.safety == .safeWhileRunning
                          || item.safety == .userConfirm
                          || (item.safety == .requiresQuit && !quitProcessRunning) {
                    Button(item.safety == .safeWhileRunning
                           ? Localized.string("detail.clean_now")
                           : Localized.string("detail.clean_confirm")) {
                        withAnimation(overlaySpring) { state.detailItem = nil }
                        Task {
                            if await service.cleanItem(item) == nil {
                                cleanFailureNotice = Localized.string("detail.clean_failed")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .focusEffectDisabled()
                    .cursorPointingHand()
                } else if item.safety == .requiresQuit {
                    if let appName = processName(for: item) {
                        Text(Localized.string("detail.clean_requires_quit_app", appName))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Localized.string("detail.clean_requires_quit"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if isKept {
                    Button(Localized.string("detail.unkeep")) {
                        service.unkeepItem(item.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .focusEffectDisabled()
                    .cursorPointingHand()
                } else {
                    Button(Localized.string("detail.keep")) {
                        service.keepItem(item)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .focusEffectDisabled()
                    .cursorPointingHand()
                }
                Spacer()
                Button(Localized.string("common.close")) {
                    withAnimation(overlaySpring) { state.detailItem = nil }
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
                .cursorPointingHand()
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
        .alert(
            Localized.string("detail.clean_failed_title"),
            isPresented: Binding(
                get: { cleanFailureNotice != nil },
                set: { if !$0 { cleanFailureNotice = nil } }
            )
        ) {
            Button(Localized.string("common.close"), role: .cancel) {}
        } message: {
            Text(cleanFailureNotice ?? "")
        }
        .onAppear {
            guard item.safety == .requiresQuit,
                  let name = processName(for: item) else {
                quitProcessRunning = false
                return
            }
            Task {
                let running = await Task.detached(priority: .userInitiated) {
                    PGrepProcessInspector().isRunning(name)
                }.value
                await MainActor.run {
                    quitProcessRunning = running
                }
            }
        }
    }

    private func processName(for item: ScanItem) -> String? {
        switch item.category {
        case .xcode:
            return "Xcode"
        case .simulator:
            return "Simulator"
        default:
            return nil
        }
    }

    /// 通用信息浮层（不可清理说明等）
    private func infoOverlay(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(overlaySpring) { showNonCleanableInfo = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .cursorPointingHand()
            }

            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(Localized.string("common.close")) {
                    withAnimation(overlaySpring) { showNonCleanableInfo = false }
                }
                .buttonStyle(PressableButtonStyle())
                .focusEffectDisabled()
                .cursorPointingHand()
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }

    private var cleanHistoryOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Localized.string("history.title"))
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(overlaySpring) { showCleanHistory = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .cursorPointingHand()
            }

            Divider()

            if state.cleanLogEntries.isEmpty {
                Text(Localized.string("history.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let groups = cleanupHistoryGroups(state.cleanLogEntries)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(group.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(historySourceText(group.source))
                                        .font(.caption2)
                                        .foregroundStyle(group.source == .auto ? Color.green : Color.orange)
                                    Spacer()
                                    Text(Format.bytes(group.freedBytes))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(group.entries) { entry in
                                    cleanHistoryItemRow(entry)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 380)
            }

            HStack {
                Spacer()
                Button(Localized.string("common.close")) {
                    withAnimation(overlaySpring) { showCleanHistory = false }
                }
                .buttonStyle(PressableButtonStyle())
                .focusEffectDisabled()
                .cursorPointingHand()
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }

    private func cleanHistoryItemRow(_ entry: CleanLogEntry) -> some View {
        HStack(spacing: 8) {
            Text(historyNames(entry))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(Format.bytes(entry.freedBytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if service.canUndo(entry) {
                Button {
                    Task { _ = await service.undoCleanup(entry) }
                } label: {
                    Label(Localized.string("history.undo"), systemImage: "arrow.uturn.backward")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .cursorPointingHand()
            }
        }
    }

    private func historyNames(_ entry: CleanLogEntry) -> String {
        if !entry.itemNames.isEmpty, entry.itemIDs.count == entry.itemNames.count {
            return zip(entry.itemIDs, entry.itemNames)
                .map { itemID, name in
                    historyItemDisplayName(itemID: itemID, fallbackName: name)
                }
                .joined(separator: ", ")
        }
        return entry.itemIDs
            .map { historyItemDisplayName(itemID: $0, fallbackName: "") }
            .joined(separator: ", ")
    }

    private func cleanupHistoryGroups(_ entries: [CleanLogEntry]) -> [CleanupHistoryGroup] {
        var groups: [String: CleanupHistoryGroup] = [:]
        var order: [String] = []
        for entry in entries {
            let key = historyGroupKey(entry)
            if var group = groups[key] {
                group.entries.append(entry)
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = CleanupHistoryGroup(
                    id: entry.batchID ?? UUID(),
                    timestamp: entry.timestamp,
                    source: entry.source,
                    entries: [entry]
                )
            }
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return CleanupHistoryGroup(
                id: group.id,
                timestamp: group.timestamp,
                source: group.source,
                entries: group.entries.sorted { $0.timestamp < $1.timestamp }
            )
        }
    }

    private func historyGroupKey(_ entry: CleanLogEntry) -> String {
        if let batchID = entry.batchID {
            return "batch-\(batchID.uuidString)"
        }
        return "legacy-\(entry.source.rawValue)-\(Int(entry.timestamp.timeIntervalSince1970))"
    }

    private func historyItemDisplayName(itemID: String, fallbackName: String) -> String {
        let parts = itemID.split(separator: ":", maxSplits: 1)
        let recipeID = parts.first.map(String.init) ?? itemID
        let path = parts.count > 1 ? String(parts[1]) : itemID
        let pathName = path.split(separator: "/").last.map(String.init) ?? path
        let parentName = Localized.recipeName(recipeID, fallback: recipeID)
        let childName = fallbackName.isEmpty ? pathName : fallbackName
        if childName == parentName || childName == pathName {
            return parentName
        }
        return "\(parentName) · \(childName)"
    }

    private func historySourceText(_ source: CleanSource) -> String {
        switch source {
        case .auto:
            return Localized.string("history.source_auto")
        case .manual:
            return Localized.string("history.source_manual")
        }
    }

    private func historyDispositionText(_ entry: CleanLogEntry) -> String {
        switch entry.disposition {
        case .trash:
            return Localized.string("history.disposition_trash")
        case .deletePermanently:
            return Localized.string("history.disposition_permanent")
        case .none:
            return Localized.string("history.disposition_none")
        }
    }

    private func estimatedTimeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return Localized.string("plan.time_today", time)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return Localized.string("plan.time_tomorrow", time)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func safetyText(for item: ScanItem) -> String {
        switch item.safety {
        case .safeWhileRunning:
            return Localized.string("safety.safe_while_running")
        case .requiresQuit:
            return Localized.string("safety.requires_quit")
        case .userConfirm:
            if CleanupRationale.make(for: item).isManual {
                return Localized.string("safety.manual_delete")
            }
            return Localized.string("safety.user_confirm")
        }
    }

    private func lastUsedText(_ date: Date?) -> String {
        guard let date else {
            return Localized.string("detail.never_used")
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 86_400 {
            let hours = max(1, Int(interval / 3600))
            return Localized.string("detail.last_used_hours", hours)
        }
        let days = Int(interval / 86_400)
        if days == 1 {
            return Localized.string("detail.last_used_yesterday")
        }
        if days == 2 {
            return Localized.string("detail.last_used_before_yesterday")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
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
            return Text(Localized.string("badge.kept"))
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(Localized.string("badge.tooltip.kept"))
        }
        if layer.recipeID == "trash" {
            return Text(Localized.string("badge.manual"))
                .font(.caption2)
                .foregroundStyle(.blue)
                .help(Localized.string("badge.tooltip.manual"))
        }
        let safety = layer.safety
        switch safety {
        case .safeWhileRunning:
            return Text(Localized.string("badge.cleanable"))
                .font(.caption2)
                .foregroundStyle(.green)
                .help(Localized.string("badge.tooltip.cleanable"))
        case .requiresQuit:
            return Text(Localized.string("badge.requires_quit"))
                .font(.caption2)
                .foregroundStyle(.red)
                .help(Localized.string("badge.tooltip.requires_quit"))
        case .userConfirm:
            return Text(Localized.string("badge.user_confirm"))
                .font(.caption2)
                .foregroundStyle(.gray)
                .help(Localized.string("badge.tooltip.user_confirm"))
        }
    }
}

private struct CleanupHistoryGroup: Identifiable {
    let id: UUID
    let timestamp: Date
    let source: CleanSource
    var entries: [CleanLogEntry]

    var freedBytes: Int64 {
        entries.reduce(Int64(0)) { $0 + $1.freedBytes }
    }
}

/// 浮层过渡统一用弹簧（critically damped，response 0.35s）
private let overlaySpring = Animation.spring(response: 0.35, dampingFraction: 1.0)

/// 按钮按下即时反馈：缩放 + 轻微透明
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// 可点击区域的统一光标声明：每个组件自己声明“我是可点击的”。
///
/// 使用 SwiftUI 原生 `.pointerStyle(.link)`（等价 AppKit cursor rect，由系统在
/// 每次鼠标移动时按命中区域刷新光标，进出不会因 hover 事件丢失而卡住）。
/// 该 API 需要 macOS 15+；macOS 14 没有可靠的 per-view 光标机制，干脆不设置，
/// 避免旧版 `.onHover` + `NSCursor.set()` 的手型卡死 bug。
extension View {
    @ViewBuilder
    func cursorPointingHand(enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? .link : .default)
        }
    }
}

/// 清理完成反馈：出水口处扩散并淡出的绿色水花
private struct CleanCelebrationView: View {
    let celebrationID: Int
    @State private var burst = false

    var body: some View {
        ZStack {
            if celebrationID > 0 {
                Circle()
                    .stroke(Color.green.opacity(0.8), lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(burst ? 5.5 : 1)
                    .opacity(burst ? 0 : 1)
                    .id(celebrationID)
                    .onAppear {
                        burst = false
                        withAnimation(.easeOut(duration: 1.1)) {
                            burst = true
                        }
                    }
            }
        }
    }
}
