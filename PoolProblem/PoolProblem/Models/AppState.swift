import Foundation
import Combine
import SwiftUI
import DiskReservoirCore

@MainActor
final class AppState: ObservableObject {
    @Published var availableBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var items: [ScanItem] = []
    @Published var lastScanAt: Date?
    @Published var predictionDays: Double?
    @Published var waterlineBytes: Int64 = 30_000_000_000
    @Published var topInflows: [(name: String, bytes: Int64)] = []
    @Published var weeklyCleanedBytes: Int64 = 0
    @Published var growthRates: [String: Double] = [:]
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var cleanedItemIDs: Set<String> = []
    @Published var deletingItemID: String?
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
    @Published var pendingClean: CleanOutcome?
    @Published var cleanOutcome: CleanOutcome?
    @Published var showCleanConfirm = false
    @Published var poolGaugeImage: Image?
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        if value == 0 { return String(localized: "0KB") }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
