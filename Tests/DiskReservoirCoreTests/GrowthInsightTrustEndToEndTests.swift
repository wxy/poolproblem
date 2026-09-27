import Foundation
import Testing
@testable import DiskReservoirCore

@Test func persistedGrowthIsHistoricalAndReconciledWithLivePaths() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-growth-trust-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let retained = home.appendingPathComponent("retained", isDirectory: true)
    let removed = home.appendingPathComponent("removed", isDirectory: true)
    try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)

    let paths = StoragePaths(baseURL: fixture.appendingPathComponent("data"), homeDirectory: home.path)
    let store = GrowthLedgerStore(paths: paths)
    let earlier = Date(timeIntervalSince1970: 1_000_000)
    let later = earlier.addingTimeInterval(2 * 86_400)
    func event(path: String, kind: GrowthKind, delta: Int64, observedAt: Date, days: Double) -> GrowthEntry {
        GrowthEntry(
            observedAt: observedAt,
            elapsedDays: days,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            pattern: path,
            kind: kind,
            deltaBytes: delta,
            rateBytesPerDay: Double(delta) / days
        )
    }
    try store.append([
        event(path: retained.path, kind: .known, delta: 100, observedAt: earlier, days: 1),
        event(path: retained.path, kind: .known, delta: 50, observedAt: later, days: 2),
        event(path: removed.path, kind: .new, delta: 500, observedAt: later, days: 2),
    ])
    try FileManager.default.removeItem(at: removed)

    let checkedAt = later.addingTimeInterval(10)
    let report = GrowthInsightReconciler().reconcile(
        entries: try store.entries(),
        checkedAt: checkedAt
    )
    #expect(report.checkedAt == checkedAt)
    #expect(report.removedCount == 1)
    #expect(report.visibleEntries.count == 1)
    let current = try #require(report.visibleEntries.first)
    #expect(current.entry.path == retained.path)
    #expect(current.entry.observedAt == later)
    #expect(current.entry.elapsedDays == 2)
    #expect(current.entry.deltaBytes == 50)
    #expect(current.pathStatus == .present)

    try FileManager.default.removeItem(at: retained)
    let afterDeletion = GrowthInsightReconciler().reconcile(entries: try store.entries())
    #expect(afterDeletion.visibleEntries.isEmpty)
    #expect(afterDeletion.removedCount == 2)
    #expect(try store.entries().count == 3) // Historical evidence remains intact.
}

@Test func aCacheNameAloneCannotCreateAnActionableRecipeSuggestion() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-growth-candidate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let cache = home.appendingPathComponent(".cache/unknown-tool", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_000_000)
    let entry = GrowthEntry(
        observedAt: observedAt,
        elapsedDays: 1,
        name: "unknown-tool",
        path: cache.path,
        pattern: "~/.cache/unknown-tool",
        kind: .surface,
        deltaBytes: 800 << 20,
        rateBytesPerDay: Double(800 << 20)
    )
    let suggested = RecipeSuggester().suggest(
        entries: [entry],
        existingRecipes: [],
        homeDirectory: home.path
    )
    #expect(suggested.isEmpty)

    // Old persisted metadata must not revive the former one-click action.
    let legacy = CandidateRecipe(
        id: entry.pattern,
        pattern: entry.pattern,
        totalGrowthBytes: entry.deltaBytes,
        peakRateBytesPerDay: entry.rateBytesPerDay,
        evidenceCount: 1,
        firstSeenAt: observedAt,
        lastSeenAt: observedAt,
        recipeID: RecipeSuggester.packageManagerFamilyID,
        recipeName: RecipeSuggester.packageManagerFamilyName,
        suggestedSafety: .safeWhileRunning,
        suggestedCleanability: .regenerable,
        suggestedCategory: .packageManager,
        suggestedDisposition: .deletePermanently,
        samplePath: cache.path
    )
    #expect(!GrowthCandidateAdmission.canAccept(legacy))
    #expect(!GrowthCandidateAdmission.canDisplay(legacy))
}

@Test func aPersistedProjectSuggestionRequiresARecognizedProjectAtItsCurrentPath() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-growth-project-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let project = fixture.appendingPathComponent("old-project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let marker = project.appendingPathComponent("package.json")
    try Data("{}".utf8).write(to: marker)
    let now = Date()
    let candidate = CandidateRecipe(
        id: project.path,
        pattern: project.path,
        totalGrowthBytes: 800 << 20,
        peakRateBytesPerDay: 0,
        evidenceCount: 1,
        firstSeenAt: now,
        lastSeenAt: now,
        recipeID: RecipeSuggester.projectFamilyID,
        recipeName: RecipeSuggester.projectFamilyName,
        suggestedSafety: .userConfirm,
        suggestedCleanability: .regenerable,
        suggestedCategory: .project,
        suggestedDisposition: .trash,
        samplePath: project.path
    )
    #expect(GrowthCandidateAdmission.canDisplay(candidate))
    try FileManager.default.removeItem(at: marker)
    #expect(!GrowthCandidateAdmission.canDisplay(candidate))
    #expect(!GrowthCandidateAdmission.canAccept(candidate))
}
