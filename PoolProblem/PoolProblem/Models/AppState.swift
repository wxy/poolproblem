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

/// 增长洞察中检测到的"疑似开发目录"，等待用户确认加入监控。
enum DevRootSource {
    case growth      // 增长量
    case discovery   // 主动发现的可重建内容
    case activity    // FSEvents 写活动（近期活跃）
}

struct DevRootCandidate: Identifiable, Equatable {
    let path: String
    let marker: String
    /// 展示的字节数：含义由 source 决定（增长/当前占用/可清理约）。
    let bytes: Int64
    let source: DevRootSource
    /// 归并到父目录的建议：列出其下项目名（供"含 N 个项目"展示）。
    let childNames: [String]
    var id: String { path }

    init(
        path: String,
        marker: String,
        bytes: Int64,
        source: DevRootSource,
        childNames: [String] = []
    ) {
        self.path = path
        self.marker = marker
        self.bytes = bytes
        self.source = source
        self.childNames = childNames
    }
}

/// 废纸篓详情页里的一条一级条目。
struct TrashEntry: Identifiable, Equatable {
    let name: String
    let bytes: Int64
    let isOwnBatch: Bool
    var id: String { name }
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
    /// 待确认的开发目录建议（增长洞察中发现，等待用户加入/忽略）。
    @Published var pendingDevRoots: [DevRootCandidate] = []
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
