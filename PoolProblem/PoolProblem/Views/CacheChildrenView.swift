import SwiftUI
import DiskReservoirCore

/// “应用缓存”等仅按子目录清理的聚合项详情：列出子目录（大小/增速/受保护），
/// 支持逐子目录清理，避免整目录删除。
struct CacheChildrenView: View {
    @ObservedObject var state: AppState
    let service: AppService
    let item: ScanItem

    @State private var children: [CacheChildEntry] = []
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Localized.recipeName(item.recipeID, fallback: item.name))
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

            Text(Localized.string("cache.children_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if children.isEmpty {
                Text(Localized.string("cache.no_children"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(children.prefix(15)) { child in
                            childRow(child)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            if let notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(Localized.string("common.close")) {
                    state.detailItem = nil
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
                .cursorPointingHand()
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
            Task { children = await service.cacheChildren(for: item) }
        }
    }

    private func childRow(_ child: CacheChildEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(child.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if child.isProtected {
                Text(Localized.string("cache.protected"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if child.ratePerDay > 0 {
                Text(Localized.string("cache.growth_rate", Format.bytes(Int64(child.ratePerDay))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(Format.bytes(child.bytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                Task {
                    await service.cleanCacheChild(path: child.path, recipeID: item.recipeID, name: child.name)
                    notice = Localized.string("cache.cleaned", child.name)
                    children = await service.cacheChildren(for: item)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.red)
            .disabled(child.isProtected)
            .help(child.isProtected
                  ? Localized.string("cache.protected_help")
                  : Localized.string("cache.clean_child"))
            .focusEffectDisabled()
            .cursorPointingHand(enabled: !child.isProtected)
        }
        .frame(height: 22)
    }
}
