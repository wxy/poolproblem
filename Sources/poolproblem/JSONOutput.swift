import DiskReservoirCore
import Foundation

enum JSONOutput {
    static func scan(result: ScanResult) throws -> Data {
        let payload: [String: Any] = [
            "version": PoolProblemCore.schemaVersion,
            "timestamp": ISO8601DateFormatter().string(from: result.volume.timestamp),
            "volume": [
                "totalBytes": result.volume.totalBytes,
                "availableBytes": result.volume.availableBytes,
            ],
            "items": result.items.map { item in
                [
                    "id": item.id,
                    "recipeID": item.recipeID,
                    "name": item.name,
                    "path": item.path,
                    "category": item.category.rawValue,
                    "safety": item.safety.rawValue,
                    "disposition": item.disposition.rawValue,
                    "sizeBytes": item.sizeBytes,
                    "allocatedBytes": item.allocatedBytes,
                    "reclaimableBytes": item.reclaimableBytes,
                    "fileCount": item.fileCount,
                ]
            },
        ]
        return try serialize(payload)
    }

    static func suggestions(_ items: [(item: ScanItem, action: EvaluatedAction)]) throws -> Data {
        let payload: [String: Any] = [
            "version": PoolProblemCore.schemaVersion,
            "suggestions": items.map { entry in
                [
                    "itemID": entry.item.id,
                    "name": entry.item.name,
                    "path": entry.item.path,
                    "action": actionName(entry.action),
                    "reason": actionReason(entry.action),
                    "reclaimableBytes": entry.item.reclaimableBytes,
                ]
            },
        ]
        return try serialize(payload)
    }

    static func clean(outcome: CleanOutcome) throws -> Data {
        let payload: [String: Any] = [
            "version": PoolProblemCore.schemaVersion,
            "freedBytes": outcome.freedBytes,
            "actualFreedBytes": outcome.actualFreedBytes,
            "stillBelowWaterline": outcome.stillBelowWaterline,
            "entries": outcome.entries.map { entry in
                [
                    "id": entry.id.uuidString,
                    "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                    "itemIDs": entry.itemIDs,
                    "freedBytes": entry.freedBytes,
                    "disposition": entry.disposition.rawValue,
                ]
            },
        ]
        return try serialize(payload)
    }

    static func status(
        snapshots: [Snapshot],
        log: [CleanLogEntry],
        prediction: Double?
    ) throws -> Data {
        let payload: [String: Any] = [
            "version": PoolProblemCore.schemaVersion,
            "snapshotCount": snapshots.count,
            "latestVolume": snapshots.last.map { volume in
                [
                    "totalBytes": volume.volume.totalBytes,
                    "availableBytes": volume.volume.availableBytes,
                    "timestamp": ISO8601DateFormatter().string(from: volume.volume.timestamp),
                ]
            } ?? [String: Any](),
            "predictionDaysUntilFull": prediction as Any,
            "recentCleans": log.suffix(10).map { entry in
                [
                    "id": entry.id.uuidString,
                    "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                    "freedBytes": entry.freedBytes,
                    "disposition": entry.disposition.rawValue,
                ]
            },
        ]
        return try serialize(payload)
    }

    private static func actionName(_ action: EvaluatedAction) -> String {
        switch action.action {
        case .skip: return "skip"
        case .trash: return "trash"
        case .delete: return "delete"
        case .notify: return "notify"
        }
    }

    private static func actionReason(_ action: EvaluatedAction) -> String {
        switch action.action {
        case .skip(let reason), .notify(let reason): return reason
        case .trash, .delete: return ""
        }
    }

    private static func serialize(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
