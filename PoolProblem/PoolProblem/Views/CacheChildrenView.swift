import SwiftUI
import Combine
import DiskReservoirCore

/// “应用缓存”和 DerivedData 的一级子目录详情；只允许主动选择单个目录移入废纸篓。
struct CacheChildrenView: View {
    @ObservedObject var state: AppState
    let service: AppService
    let item: ScanItem

    @State private var children: [ChildDirectoryInfo] = []
    @State private var notice: String?
    @State private var isLoading = true
    @State private var xcodeRunning = false
    @State private var currentDate = Date()
    @State private var pendingChild: ChildDirectoryInfo?
    @State private var cleaningChildID: String?

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
            if item.recipeID == "deriveddata" && xcodeRunning {
                Text(Localized.string("cache.xcode_running_warning"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if children.isEmpty {
                Text(Localized.string("cache.no_children"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(children) { child in
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
            xcodeRunning = item.recipeID == "deriveddata"
                && PGrepProcessInspector().isRunning("Xcode")
            Task {
                children = await service.cacheChildren(for: item)
                isLoading = false
            }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { date in
            currentDate = date
        }
        .alert(item: $pendingChild) { child in
            Alert(
                title: Text(Localized.string("cache.confirm_title")),
                message: Text(confirmMessage(for: child)),
                primaryButton: .destructive(Text(Localized.string("cache.confirm_move"))) {
                    cleaningChildID = child.id
                    Task {
                        let cleaned = await service.cleanCacheChild(child, in: item)
                        notice = cleaned
                            ? Localized.string("cache.cleaned", child.name)
                            : Localized.string("cache.clean_failed")
                        children = await service.cacheChildren(for: item)
                        cleaningChildID = nil
                    }
                },
                secondaryButton: .cancel(Text(Localized.string("common.cancel")))
            )
        }
    }

    private func childRow(_ child: ChildDirectoryInfo) -> some View {
        let derived = item.recipeID == "deriveddata"
        let writing = derived && (child.lastModified.map {
            $0 > currentDate.addingTimeInterval(-DerivedDataChildPolicy.minimumIdleSeconds)
        } ?? true)
        let recentlyUsed = derived && (child.lastModified.map {
            $0 > currentDate.addingTimeInterval(-86_400)
        } ?? false)
        let shared = derived && DerivedDataChildPolicy.isSharedCache(name: child.name)
        let blocked = child.isProtected || writing || cleaningChildID != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    FinderReveal.reveal(child.path)
                } label: {
                    Text(child.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(Localized.string("cache.open_in_finder"))
                .focusEffectDisabled()
                .cursorPointingHand()
                if child.isProtected {
                    Text(Localized.string("cache.protected"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if shared {
                    Text(Localized.string("cache.shared"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if recentlyUsed {
                    Text(Localized.string("cache.recent"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Format.bytes(child.bytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    pendingChild = child
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .disabled(blocked)
                .help(child.isProtected
                      ? Localized.string("cache.protected_help")
                      : (writing
                         ? Localized.string("cache.recent_help")
                         : Localized.string("cache.clean_child")))
                .focusEffectDisabled()
                .cursorPointingHand(enabled: !blocked)
            }
            if let growth = child.growth {
                Text(Localized.string(
                    "cache.observed_growth",
                    Format.bytes(growth.deltaBytes),
                    observationDuration(growth.elapsedDays),
                    growth.observedAt.formatted(date: .abbreviated, time: .shortened)
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    private func confirmMessage(for child: ChildDirectoryInfo) -> String {
        let message: String
        if item.recipeID == "deriveddata" {
            message = DerivedDataChildPolicy.isSharedCache(name: child.name)
                ? Localized.string("cache.confirm_shared", child.name, Format.bytes(child.bytes))
                : Localized.string("cache.confirm_project", child.name, Format.bytes(child.bytes))
        } else {
            message = Localized.string("cache.confirm_cache", child.name, Format.bytes(child.bytes))
        }
        return xcodeRunning && item.recipeID == "deriveddata"
            ? message + "\n\n" + Localized.string("cache.xcode_running_warning")
            : message
    }

    private func observationDuration(_ days: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, days * 86_400)) ?? ""
    }
}
