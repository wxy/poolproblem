import Foundation
import Combine
import SwiftUI
import DiskReservoirCore

struct AutoCleanPlanItem: Identifiable {
    let id: UUID
    let title: String
    let estimatedDate: Date?
    let progress: Double
}

/// 废纸篓详情页里的一条一级条目。
struct TrashEntry: Identifiable, Equatable {
    let name: String
    let bytes: Int64
    let isOwnBatch: Bool
    var id: String { name }
}

/// 应用缓存详情页里的一级子目录条目。
struct CacheChildEntry: Identifiable, Equatable {
    let name: String
    let path: String
    let bytes: Int64
    let ratePerDay: Double
    let isProtected: Bool
    var id: String { path }
}

enum DashboardConsistencyStatus: Equatable {
    case current
    case reconciling
    case partial
}

@MainActor
final class AppState: ObservableObject {
    @Published var availableBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var items: [ScanItem] = []
    @Published var lastScanAt: Date?
    @Published var consistencyStatus: DashboardConsistencyStatus = .current
    @Published var predictionDays: Double?
    @Published var autoCleanPlan = ""
    @Published var autoCleanPlans: [AutoCleanPlanItem] = []
    @Published var waterlineBytes: Int64 = 30_000_000_000
    @Published var topInflows: [(name: String, bytes: Int64)] = []
    @Published var weeklyCleanedBytes: Int64 = 0
    @Published var growthRates: [String: Double] = [:]
    @Published var isScanning = false
    @Published var isCleaning = false
    /// Drives expensive decorative animation only while the popover is visible.
    @Published var isPopoverVisible = false
    @Published var cleanedItemIDs: Set<String> = []
    @Published var deletingItemID: String?
    /// 正在删除的条目剩余比例：1 → 0，用于列表里大小逐渐缩小到消失的动画。
    @Published var deletingProgress: Double = 1
    @Published var lastCleanSummary: String?
    @Published var detailItem: ScanItem?
    @Published var keptItemIDs: Set<String> = []
    @Published var availableHistory: [Int64] = []
    @Published var weeklyNetChangeBytes: Int64 = 0
    @Published var historyTimestamps: [Date] = []
    @Published var cleaningEvents: [(timestamp: Date, freedBytes: Int64, isManual: Bool)] = []
    @Published var cleanLogEntries: [CleanLogEntry] = []
    @Published var pendingClean: CleanOutcome?
    @Published var cleanOutcome: CleanOutcome?
    @Published var showCleanConfirm = false
    @Published var poolGaugeImage: Image?
    @Published var cleanCelebrationID = 0
    /// 历史增长事件与当前路径存在性的轻量核对；不代表当前占用。
    @Published var growthReport: GrowthInsightReport?
    @Published var isGrowthDiscovering = false
    @Published var growthDiscoveryMessage: String?
    /// 候选配方（含用户已采纳/忽略的状态）。
    @Published var candidateRecipes: [CandidateRecipe] = []
    /// 菜单栏面板"增长洞察"明细 sheet 开关。
    @Published var showGrowthInsights = false
    /// 待确认的开发目录建议（增长洞察中发现，等待用户加入/忽略）。

    /// Upper bound of data whose recipe explicitly authorizes unattended,
    /// permanent deletion. Runtime age and process guards can only reduce it.
    var automaticDeletionCeilingBytes: Int64 {
        items.reduce(into: Int64(0)) { total, item in
            guard item.allowsAutomaticPermanentDeletion,
                  item.cleanability == .regenerable,
                  item.disposition == .deletePermanently else { return }
            total += item.reclaimableBytes
        }
    }

    var pressureState: DiskPressureState {
        DiskPressurePolicy(targetBytes: waterlineBytes)
            .state(availableBytes: availableBytes)
    }

    var recoveryDeficitBytes: Int64 {
        let recovery = DiskPressurePolicy(targetBytes: waterlineBytes)
            .recoveryTargetBytes
        return max(0, recovery - availableBytes)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        if value == 0 { return String(localized: "0KB") }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func signedBytes(_ value: Int64) -> String {
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        return sign + bytes(abs(value))
    }
}
