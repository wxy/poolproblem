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
            if entry.kind == .unknownSpace || entry.kind == .surface {
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
            Text(Localized.string("insights.rate", Format.bytes(Int64(entry.rateBytesPerDay))))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private func displayName(_ entry: GrowthEntry) -> String {
        entry.kind == .unknownSpace ? Localized.string("insights.unknown_space") : entry.pattern
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
