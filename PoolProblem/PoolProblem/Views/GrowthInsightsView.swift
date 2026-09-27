import SwiftUI
import DiskReservoirCore

/// 增长洞察：历史观测、轻量路径核对与项目范围提议。
struct GrowthInsightsView: View {
    private enum Section: Hashable {
        case changes
        case watched
        case projects
    }

    @ObservedObject var state: AppState
    let service: AppService
    @State private var selectedSection: Section = .changes
    @State private var candidateToConfirm: CandidateRecipe?

    private var pendingCandidates: [CandidateRecipe] {
        state.candidateRecipes.filter {
            $0.status == .pending && GrowthCandidateAdmission.canDisplay($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker(Localized.string("insights.title"), selection: $selectedSection) {
                Text(Localized.string("insights.tab_changes")).tag(Section.changes)
                Text(Localized.string("insights.tab_watched")).tag(Section.watched)
                Text(Localized.string("insights.tab_projects")).tag(Section.projects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                sectionContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 440, height: 470)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
        .onAppear { service.recheckGrowthInsights() }
        .alert(item: $candidateToConfirm) { candidate in
            Alert(
                title: Text(Localized.string("candidate.preview_title")),
                message: Text(Localized.string("candidate.preview_body", candidate.samplePath)),
                primaryButton: .default(Text(Localized.string("candidate.confirm_add"))) {
                    service.acceptCandidate(id: candidate.id)
                },
                secondaryButton: .cancel(Text(Localized.string("common.cancel")))
            )
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .changes: growthLogSection
        case .watched: watchSection
        case .projects: candidateSection
        }
    }

    private var header: some View {
        HStack {
            Text(Localized.string("insights.title"))
                .font(.headline)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { state.showGrowthInsights = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .cursorPointingHand()
            .accessibilityLabel(Localized.string("common.close"))
        }
    }

    private var growthLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Localized.string("insights.recent_events"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            Text(Localized.string("insights.historical_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(Localized.string("insights.recheck_paths")) {
                    service.recheckGrowthInsights()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .cursorPointingHand()
                Button(state.isGrowthDiscovering
                    ? Localized.string("insights.drilling")
                    : Localized.string("insights.drill")
                ) {
                    Task { await service.discoverGrowthSources() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isGrowthDiscovering)
                .cursorPointingHand()
                .help(Localized.string("insights.discovery_scope"))
                Spacer()
            }
            if let message = state.growthDiscoveryMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let report = state.growthReport {
                Text(Localized.string("insights.checked_at", dateText(report.checkedAt)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if report.removedCount > 0 {
                    Text(Localized.string("insights.removed_count", report.removedCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if state.growthReport?.visibleEntries.isEmpty != false {
                Text(Localized.string("insights.no_current_paths"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.growthReport?.visibleEntries.prefix(20) ?? []) { record in
                        growthRow(record)
                    }
                }
            }
        }
    }

    private func growthRow(_ record: GrowthInsightVisibleEntry) -> some View {
        let entry = record.entry
        return Button {
            if !entry.path.isEmpty {
                revealInFinder(entry.path)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(entry.pattern)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.kind == .surface {
                        Text(Localized.string("insights.surface_badge"))
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.kind == .new
                         ? Localized.string("insights.first_size", Format.bytes(entry.deltaBytes))
                         : Localized.string("insights.interval_growth", Format.bytes(entry.deltaBytes)))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Spacer()
                    Label(
                        record.pathStatus == .present
                            ? Localized.string("insights.path_present_short")
                            : Localized.string("insights.path_unknown_short"),
                        systemImage: record.pathStatus == .present
                            ? "checkmark.circle" : "questionmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(record.pathStatus == .present
                          ? Localized.string("insights.path_exists_unmeasured")
                          : Localized.string("insights.path_unknown"))
                }
                Text(observationText(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .cursorPointingHand()
        .help(entry.path)
    }

    /// Observed assets stay outside every cleanup entry point. The figure is
    /// allocated disk space, while reclaimable space remains zero.
    private var watchSection: some View {
        let watchItems = service.visibleItems(state.items)
            .filter {
                $0.cleanability == .watchOnly
                    && $0.recipeID != OwnerCommandRecipe.pnpmStorePrune.id
                    && $0.paths.contains { GrowthPathStatus.probe($0) != .missing }
            }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
        return VStack(alignment: .leading, spacing: 10) {
            Text(Localized.string("insights.watch_section"))
                .font(.subheadline)
                .fontWeight(.semibold)
            if let lastScanAt = state.lastScanAt {
                Text(Localized.string("insights.watch_measured_at", dateText(lastScanAt)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if watchItems.isEmpty {
                Text(Localized.string("insights.watch_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(watchItems) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button {
                            if let path = item.paths.first(where: {
                                GrowthPathStatus.probe($0) == .present
                            }) ?? item.paths.first {
                                revealInFinder(path)
                            }
                        } label: {
                            Text(Localized.recipeName(item.recipeID, fallback: item.name))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .cursorPointingHand()
                        .help(item.paths.joined(separator: "\n"))
                        Spacer()
                        Text(Format.bytes(item.allocatedBytes))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help(Localized.string("insights.watch_size_help"))
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func observationText(_ entry: GrowthEntry) -> String {
        if entry.kind == .new {
            return Localized.string("insights.recorded_at", dateText(entry.observedAt))
        }
        let start = entry.observedAt.addingTimeInterval(-max(0, entry.elapsedDays) * 86_400)
        return Localized.string("insights.interval", dateText(start), dateText(entry.observedAt))
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Localized.string("candidate.project_section"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(Localized.string("candidate.recheck")) {
                    Task { await service.refreshSuggestions(forceDiscovery: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .cursorPointingHand()
            }
            Text(Localized.string("candidate.project_hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if pendingCandidates.isEmpty {
                Text(Localized.string("candidate.project_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(pendingCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: CandidateRecipe) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    revealInFinder(candidate.samplePath)
                } label: {
                    Text(candidate.pattern)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .cursorPointingHand()
                .help(candidate.samplePath)
                Spacer()
            }
            if !candidate.childNames.isEmpty {
                Text(Localized.string(
                    "devroot.group_subtitle",
                    candidate.childNames.count,
                    candidate.childNames.prefix(3).joined(separator: ", ")
                        + (candidate.childNames.count > 3 ? "…" : "")
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Text(candidateSourceText(candidate)
                 + " · " + Localized.string("candidate.last_seen", dateText(candidate.lastSeenAt)))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Localized.string("candidate.preview")) {
                    candidateToConfirm = candidate
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .cursorPointingHand()
                Button(Localized.string("candidate.dismiss")) {
                    service.dismissCandidate(id: candidate.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .cursorPointingHand()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 建议来源说明：为什么该目录会被建议纳入配方。
    private func candidateSourceText(_ candidate: CandidateRecipe) -> String {
        switch candidate.source {
        case .growth:
            return Localized.string("candidate.historical_growth", Format.bytes(candidate.totalGrowthBytes))
        case .discovery:
            return Localized.string("candidate.project_artifacts", Format.bytes(candidate.totalGrowthBytes))
        case .activity:
            return Localized.string("candidate.recent_activity")
        }
    }

    private func revealInFinder(_ path: String) {
        FinderReveal.reveal(path)
    }
}
