import SwiftUI
import DiskReservoirCore

/// 增长洞察弹层：增长记录 + 候选配方建议（采纳/忽略）。
struct GrowthInsightsView: View {
    @ObservedObject var state: AppState
    let service: AppService

    private var pendingCandidates: [CandidateRecipe] {
        state.candidateRecipes.filter { $0.status == .pending }
    }

    private var acceptedCandidates: [CandidateRecipe] {
        state.candidateRecipes.filter { $0.status == .accepted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    growthLogSection
                    Divider()
                    if !state.pendingDevRoots.isEmpty {
                        devRootSection
                        Divider()
                    }
                    candidateSection
                }
            }
            .frame(maxHeight: 380)

            HStack {
                Spacer()
                Button(Localized.string("common.close")) {
                    withAnimation(.easeInOut(duration: 0.18)) { state.showGrowthInsights = false }
                }
                .buttonStyle(.bordered)
                .cursorPointingHand()
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.15))
            .onAppear {
                if state.pendingDevRoots.isEmpty {
                    Task { await service.refreshDevSuggestions(force: true) }
                }
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
        }
    }

    private var growthLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Localized.string("insights.entries"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if state.growthInsights.isEmpty {
                Text(Localized.string("insights.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.growthInsights.prefix(20)) { entry in
                    growthRow(entry)
                }
            }
        }
    }

    private func growthRow(_ entry: GrowthEntry) -> some View {
        HStack(spacing: 6) {
            Text(displayName(entry))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.kind == .surface {
                Text(Localized.string("insights.new_badge"))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange))
            }
            Spacer()
            Text(Format.bytes(entry.deltaBytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(growthRateText(entry))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// 速率展示：观测窗口足够长（≥1 天）才外推为"每天"，
    /// 否则显示真实观测窗口（如"近 30 分钟"），避免把短时突发外推成夸张的日增量。
    private func growthRateText(_ entry: GrowthEntry) -> String {
        if entry.elapsedDays >= 0.9 {
            return Localized.string("insights.rate", Format.bytes(Int64(entry.rateBytesPerDay)))
        }
        return Localized.string("insights.observed", windowText(entry.elapsedDays))
    }

    private func windowText(_ elapsedDays: Double) -> String {
        let minutes = Int((elapsedDays * 24 * 60).rounded())
        if minutes < 60 {
            return Localized.string("time.minutes", minutes)
        }
        if minutes < 24 * 60 {
            return Localized.string("time.hours", minutes / 60)
        }
        return Localized.string("time.days", Int(elapsedDays.rounded()))
    }

    private func displayName(_ entry: GrowthEntry) -> String {
        entry.pattern
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Localized.string("insights.candidates"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if pendingCandidates.isEmpty && acceptedCandidates.isEmpty {
                Text(Localized.string("insights.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pendingCandidates) { candidate in
                    candidateRow(candidate)
                }
                if !acceptedCandidates.isEmpty {
                    Divider()
                    ForEach(acceptedCandidates) { candidate in
                        acceptedRow(candidate)
                    }
                }
            }
        }
    }

    private var devRootSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Localized.string("devroot.section_title"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(Localized.string("devroot.rescan")) {
                    Task { await service.refreshDevSuggestions(force: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .cursorPointingHand()
            }
            Text(Localized.string("devroot.hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(state.pendingDevRoots) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(PathPatternizer.patternize(candidate.path))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if candidate.childNames.isEmpty {
                            Text(Localized.string("devroot.marker", candidate.marker))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
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
                    }
                    HStack {
                        Text(devRootBytesText(candidate))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(Localized.string("devroot.add")) {
                            service.confirmDevRoot(candidate.path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .cursorPointingHand()
                        Button(Localized.string("devroot.ignore")) {
                            service.declineDevRoot(candidate.path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .cursorPointingHand()
                    }
                }
            }
        }
    }

    private func devRootBytesText(_ candidate: DevRootCandidate) -> String {
        switch candidate.source {
        case .growth:
            return Localized.string("devroot.growth", Format.bytes(candidate.bytes))
        case .discovery:
            return Localized.string("devroot.cleanable", Format.bytes(candidate.bytes))
        case .activity:
            return Localized.string("devroot.active")
        }
    }

    private func candidateRow(_ candidate: CandidateRecipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(candidate.pattern)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(candidate.suggestedSafety == .safeWhileRunning
                     ? Localized.string("candidate.safety_safe")
                     : Localized.string("candidate.safety_confirm"))
                    .font(.caption2)
                    .foregroundStyle(candidate.suggestedSafety == .safeWhileRunning ? Color.green : Color.orange)
            }
            HStack {
                Text(Localized.string("candidate.evidence", candidate.evidenceCount)
                     + " · " + Format.bytes(candidate.totalGrowthBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(Localized.string("candidate.accept")) {
                    service.acceptCandidate(id: candidate.id)
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
    }

    private func acceptedRow(_ candidate: CandidateRecipe) -> some View {
        HStack(spacing: 6) {
            Text(candidate.pattern)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(Localized.string("common.remove")) {
                service.dismissCandidate(id: candidate.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .cursorPointingHand()
        }
    }
}
