import Foundation
import Combine
import DiskReservoirCore

@MainActor
final class AppState: ObservableObject {
    @Published var availableBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var items: [ScanItem] = []
    @Published var lastScanAt: Date?
    @Published var predictionDays: Double?
    @Published var isScanning = false
    @Published var pendingClean: CleanOutcome?
    @Published var cleanOutcome: CleanOutcome?
    @Published var showCleanConfirm = false
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
