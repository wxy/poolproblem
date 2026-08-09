import Foundation

public struct AttributionReport: Codable, Equatable, Sendable {
    public let windowDays: Int
    public let categoryDeltas: [Category: Int64]
    public let recipeDeltas: [String: Int64]
    public let totalDelta: Int64

    public init(windowDays: Int, categoryDeltas: [Category: Int64], recipeDeltas: [String: Int64], totalDelta: Int64) {
        self.windowDays = windowDays
        self.categoryDeltas = categoryDeltas
        self.recipeDeltas = recipeDeltas
        self.totalDelta = totalDelta
    }
}

public struct RegrowthReport: Codable, Equatable, Sendable {
    public let recipeID: String
    public let itemID: String
    public let name: String
    public let cleanedBytes: Int64
    public let regrownBytes: Int64

    public init(recipeID: String, itemID: String, name: String, cleanedBytes: Int64, regrownBytes: Int64) {
        self.recipeID = recipeID
        self.itemID = itemID
        self.name = name
        self.cleanedBytes = cleanedBytes
        self.regrownBytes = regrownBytes
    }
}

public struct GrowthThresholds: Equatable, Sendable {
    public var absoluteBytes: Int64
    public var relativePercent: Double
    public var minimumAbsoluteBytes: Int64

    public init(absoluteBytes: Int64, relativePercent: Double, minimumAbsoluteBytes: Int64) {
        self.absoluteBytes = absoluteBytes
        self.relativePercent = relativePercent
        self.minimumAbsoluteBytes = minimumAbsoluteBytes
    }

    public static let `default` = GrowthThresholds(
        absoluteBytes: 2 << 30,
        relativePercent: 0.5,
        minimumAbsoluteBytes: 500 << 20
    )
}

public struct GrowthAlert: Equatable, Sendable {
    public let itemID: String
    public let name: String
    public let deltaBytes: Int64

    public init(itemID: String, name: String, deltaBytes: Int64) {
        self.itemID = itemID
        self.name = name
        self.deltaBytes = deltaBytes
    }
}

public struct FlowAnalyzer: Sendable {
    public init() {}

    public func attribution(snapshots: [Snapshot], windowDays: Int = 7) -> AttributionReport {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let inWindow = snapshots.filter { $0.volume.timestamp >= cutoff }
        guard let first = inWindow.first, let last = inWindow.last,
              first.volume.timestamp < last.volume.timestamp else {
            return AttributionReport(windowDays: windowDays, categoryDeltas: [:], recipeDeltas: [:], totalDelta: 0)
        }
        let firstByID = Dictionary(uniqueKeysWithValues: first.items.map { ($0.id, $0.sizeBytes) })
        let lastByID = Dictionary(uniqueKeysWithValues: last.items.map { ($0.id, $0.sizeBytes) })
        var recipeDeltas: [String: Int64] = [:]
        var categoryDeltas: [Category: Int64] = [:]
        for (id, oldSize) in firstByID {
            let newSize = lastByID[id] ?? 0
            let delta = newSize - oldSize
            if let item = last.items.first(where: { $0.id == id }) ?? first.items.first(where: { $0.id == id }) {
                recipeDeltas[item.recipeID, default: 0] += delta
                categoryDeltas[item.category, default: 0] += delta
            }
        }
        for (id, newSize) in lastByID where firstByID[id] == nil {
            if let item = last.items.first(where: { $0.id == id }) {
                recipeDeltas[item.recipeID, default: 0] += newSize
                categoryDeltas[item.category, default: 0] += newSize
            }
        }
        let total = recipeDeltas.values.reduce(0, +)
        return AttributionReport(
            windowDays: windowDays,
            categoryDeltas: categoryDeltas,
            recipeDeltas: recipeDeltas,
            totalDelta: total
        )
    }

    public func growthAlert(snapshots: [Snapshot], thresholds: GrowthThresholds = .default) -> GrowthAlert? {
        guard let first = snapshots.first, let last = snapshots.last,
              last.volume.timestamp.timeIntervalSince(first.volume.timestamp) >= 86_400 else { return nil }
        let firstByID = Dictionary(uniqueKeysWithValues: first.items.map { ($0.id, $0.sizeBytes) })
        for item in last.items {
            guard let old = firstByID[item.id] else { continue }
            let delta = item.sizeBytes - old
            let overAbsolute = delta > thresholds.absoluteBytes
            let overRelative = delta > Int64(Double(old) * thresholds.relativePercent)
                && delta > thresholds.minimumAbsoluteBytes
            if overAbsolute || overRelative {
                return GrowthAlert(itemID: item.id, name: item.name, deltaBytes: delta)
            }
        }
        return nil
    }

    public func regrowth(snapshots: [Snapshot], log: [CleanLogEntry]) -> [RegrowthReport] {
        guard let last = snapshots.last else { return [] }
        let lastByID = Dictionary(uniqueKeysWithValues: last.items.map { ($0.id, $0.sizeBytes) })
        var result: [RegrowthReport] = []
        for entry in log {
            for itemID in entry.itemIDs {
                let regrown = lastByID[itemID] ?? 0
                if regrown > 0, let item = last.items.first(where: { $0.id == itemID }) {
                    result.append(RegrowthReport(
                        recipeID: item.recipeID,
                        itemID: itemID,
                        name: item.name,
                        cleanedBytes: entry.freedBytes,
                        regrownBytes: regrown
                    ))
                }
            }
        }
        return result
    }
}
