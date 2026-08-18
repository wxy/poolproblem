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

@MainActor
final class AppState: ObservableObject {
    @Published var availableBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var items: [ScanItem] = []
    @Published var lastScanAt: Date?
    @Published var predictionDays: Double?
    @Published var autoCleanPlan = ""
    @Published var autoCleanPlans: [AutoCleanPlanItem] = []
    @Published var waterlineBytes: Int64 = 30_000_000_000
    @Published var topInflows: [(name: String, bytes: Int64)] = []
    @Published var weeklyCleanedBytes: Int64 = 0
    @Published var growthRates: [String: Double] = [:]
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var cleanedItemIDs: Set<String> = []
    @Published var deletingItemID: String?
    /// 正在删除的条目剩余比例：1 → 0，用于列表里大小逐渐缩小到消失的动画。
    @Published var deletingProgress: Double = 1
    @Published var lastCleanSummary: String?
    @Published var trashExpanded = false
    @Published var ourTrashNames: [String] = []
    @Published var ourTrashBytes: Int64 = 0
    @Published var trashOthersBytes: Int64 = 0
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
    /// 增长洞察：最近的增长台账条目（新→旧）。
    @Published var growthInsights: [GrowthEntry] = []
    /// 候选配方（含用户已采纳/忽略的状态）。
    @Published var candidateRecipes: [CandidateRecipe] = []
    /// 菜单栏面板"增长洞察"明细 sheet 开关。
    @Published var showGrowthInsights = false
    /// 未覆盖空间下钻结果：按需表面扫描得到的增长目录（新→旧）。
    @Published var unknownDrillDown: [GrowthEntry] = []
    /// 下钻时按当前占用大小排序的目录（无显著增长时供排查）。
    @Published var unknownDrillDownTopSize: [SurfaceDirectory] = []
    /// 下钻时表面基线尚不存在（首次点击只建立基线）。
    @Published var unknownDrillDownBaselineMissing = false
    /// 下钻扫描进行中。
    @Published var isDrillingDown = false
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
