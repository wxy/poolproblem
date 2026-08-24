import SwiftUI
import DiskReservoirCore

/// 废纸篓详情页：列出当前条目，提供“清空/恢复本应用批次”操作与后果说明。
/// 废纸篓是安全过渡区，应用不自动清理；用户手动放入的内容永远不会被触碰。
struct TrashDetailView: View {
    @ObservedObject var state: AppState
    let service: AppService

    @State private var entries: [TrashEntry] = []
    @State private var notice: String?

    var body: some View {
        let own = entries.filter(\.isOwnBatch)
        let othersTotal = entries
            .filter { !$0.isOwnBatch }
            .reduce(Int64(0)) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Localized.string("recipe.trash"))
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation { state.detailItem = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
                .cursorPointingHand()
            }

            if entries.isEmpty {
                Text(Localized.string("trash.fda_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !own.isEmpty {
                            Text(Localized.string("trash.section_own_batches"))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(own) { entry in
                                ownBatchRow(entry)
                            }
                        }
                        if othersTotal > 0 {
                            Text(Localized.string("trash.section_others"))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.bytes(othersTotal))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 20)
                            Text(Localized.string("trash.manual_note"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            Divider()

            Text(Localized.string("trash.why_manual_title"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(Localized.string("trash.why_manual_body"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Localized.string("trash.empty_consequence"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(Localized.string("trash.empty_consequence_body"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Localized.string("trash.restore_consequence"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(Localized.string("trash.restore_consequence_body"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 10) {
                Button(Localized.string("trash.empty_own")) {
                    Task {
                        await service.emptyOwnTrashBatches()
                        notice = Localized.string("trash.empty_done")
                        await reload()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(own.isEmpty)
                .focusEffectDisabled()
                .cursorPointingHand()

                Button(Localized.string("trash.restore_own")) {
                    Task {
                        let count = await service.restoreOwnTrashBatches()
                        notice = Localized.string("trash.restore_done", count)
                        await reload()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(own.isEmpty)
                .focusEffectDisabled()
                .cursorPointingHand()

                Spacer()
                Button(Localized.string("common.close")) {
                    state.detailItem = nil
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
                .cursorPointingHand()
            }

            if let notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
        .onAppear {
            Task { await reload() }
        }
    }

    private func reload() async {
        entries = await service.trashEntries()
    }

    private func ownBatchRow(_ entry: TrashEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(Format.bytes(entry.bytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                Task {
                    let count = await service.restoreOwnBatch(named: entry.name)
                    notice = Localized.string("trash.restore_done", count)
                    await reload()
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(Localized.string("trash.restore_own"))
            .focusEffectDisabled()
            .cursorPointingHand()
            Button {
                Task {
                    await service.emptyOwnBatch(named: entry.name)
                    notice = Localized.string("trash.empty_done")
                    await reload()
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.red)
            .help(Localized.string("trash.empty_own"))
            .focusEffectDisabled()
            .cursorPointingHand()
        }
        .frame(height: 20)
    }
}
