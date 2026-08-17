import Testing
import Foundation
@testable import DiskReservoirCore

private func item(
    _ recipeID: String,
    safety: SafetyLevel = .safeWhileRunning,
    disposition: CleanDisposition = .trash,
    cleanability: Cleanability = .regenerable,
    modified: Date? = Date()
) -> ScanItem {
    ScanItem(
        id: "\(recipeID):/tmp/x",
        recipeID: recipeID,
        name: "N",
        path: "/tmp/x",
        category: .common,
        safety: safety,
        disposition: disposition,
        sizeBytes: 1,
        allocatedBytes: 1,
        reclaimableBytes: 1,
        fileCount: 1,
        lastModified: modified,
        cleanability: cleanability
    )
}

@Test func staleRuntimeItemSuggestsManualXcodeDeletion() {
    let used = Date(timeIntervalSince1970: 1_000_000)
    let rationale = CleanupRationale.make(for: item(
        "simulator-runtimes",
        safety: .userConfirm,
        modified: used
    ))
    #expect(rationale.suggestion == .unusedSimulatorRuntime)
    #expect(rationale.confirmation == .manualXcodeComponents)
    #expect(rationale.lastUsed == used)
}

@Test func recentlyUsedRuntimeIsNotSuggested() {
    let rationale = CleanupRationale.make(for: item(
        "simulator-runtimes",
        safety: .userConfirm,
        modified: Date()
    ))
    #expect(rationale.suggestion == .simulatorRuntimeInUse)
    #expect(rationale.confirmation == .manualXcodeComponents)
}

@Test func dyldCacheFollowsRuntimeUsage() {
    let stale = CleanupRationale.make(for: item(
        "simulator-dyld-cache",
        safety: .userConfirm,
        modified: Date(timeIntervalSince1970: 1_000_000)
    ))
    #expect(stale.suggestion == .unusedSimulatorSharedCache)
    #expect(stale.confirmation == .manualXcodeComponents)

    let recent = CleanupRationale.make(for: item(
        "simulator-dyld-cache",
        safety: .userConfirm,
        modified: Date()
    ))
    #expect(recent.suggestion == .simulatorSharedCacheInUse)
    #expect(recent.confirmation == .manualXcodeComponents)
}

@Test func deviceSupportOldVersionsNeedRedownload() {
    let rationale = CleanupRationale.make(for: item(
        "xcode-devicesupport",
        safety: .userConfirm
    ))
    #expect(rationale.suggestion == .oldDeviceSupport)
    #expect(rationale.confirmation == .reDownload)
}

@Test func simulatorDevicesAreNonRegenerable() {
    let rationale = CleanupRationale.make(for: item(
        "core-simulator-devices",
        safety: .requiresQuit,
        cleanability: .trashOnly
    ))
    #expect(rationale.suggestion == .simulatorDeviceData)
    #expect(rationale.confirmation == .nonRegenerable)
}

@Test func displayOnlyIsUserData() {
    let rationale = CleanupRationale.make(for: item(
        "trash",
        safety: .userConfirm,
        disposition: .none,
        cleanability: .displayOnly
    ))
    #expect(rationale.suggestion == .userDataOnly)
    #expect(rationale.confirmation == nil)
}

@Test func regenerableCacheNeedsNoConfirmation() {
    let rationale = CleanupRationale.make(for: item("npm-cache"))
    #expect(rationale.suggestion == .regenerable)
    #expect(rationale.confirmation == nil)
}
