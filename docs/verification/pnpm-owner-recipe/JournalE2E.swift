import Foundation

private final class SaveCounter: @unchecked Sendable { var count = 0 }
private struct FailAtSave: JSONStoring {
    let failureIndex: Int
    let counter: SaveCounter
    let base = JSONStore()
    func save<T: Encodable>(_ value: T, to url: URL) throws {
        counter.count += 1
        if counter.count == failureIndex { throw CocoaError(.fileWriteNoPermission) }
        try base.save(value, to: url)
    }
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        try base.load(type, from: url)
    }
}

@main struct JournalE2E {
    static func main() throws {
        let home = ProcessInfo.processInfo.environment["HOME"]!
        let executable = ProcessInfo.processInfo.environment["FIXTURE_EXECUTABLE"]!
        let storePath = home + "/store"
        let fm = FileManager.default
        try fm.createDirectory(atPath: storePath, withIntermediateDirectories: true)
        let runner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: executable,
                                        environment: ProcessInfo.processInfo.environment, home: home)
        let target = try runner.probe().get()
        func check(_ value: Bool, _ name: String) { if !value { fatalError(name) }; print("PASS " + name) }
        func package() throws { try Data("package".utf8).write(to: URL(fileURLWithPath: storePath + "/unreferenced-package")) }
        func invocations() -> Int { ((try? String(contentsOfFile: home + "/invocations", encoding: .utf8)) ?? "").split(separator: "\n").count }
        func paths(_ name: String) -> StoragePaths { StoragePaths(baseURL: URL(fileURLWithPath: home + "/" + name), homeDirectory: home) }

        try package()
        let noStartPaths = paths("no-start")
        let noStartStore = OwnerCommandRecordStore(paths: noStartPaths, store: FailAtSave(failureIndex: 1, counter: SaveCounter()))
        let before = invocations()
        let noStart = OwnerCommandJournal(store: noStartStore).execute(recipeID: "pnpm-store-prune", targetPath: target.path) {
            runner.perform(confirmed: target)
        }
        if case .startNotSaved = noStart { check(true, "failed attempt journal blocks command") } else { fatalError("unexpected start result") }
        check(invocations() == before && fm.fileExists(atPath: storePath + "/unreferenced-package"), "failed journal leaves package untouched")

        let lostPaths = paths("completion-lost")
        let lostStore = OwnerCommandRecordStore(paths: lostPaths, store: FailAtSave(failureIndex: 2, counter: SaveCounter()))
        let lost = OwnerCommandJournal(store: lostStore).execute(recipeID: "pnpm-store-prune", targetPath: target.path) {
            runner.perform(confirmed: target)
        }
        if case .completionNotSaved(.success, let attempt) = lost { check(attempt.outcome == "started", "completion write failure reports known command success separately") }
        else { fatalError("unexpected completion result") }
        check(!fm.fileExists(atPath: storePath + "/unreferenced-package"), "command can succeed despite history failure")
        check(try lostStore.entries().map(\.outcome) == ["started"], "persisted attempt remains explicitly incomplete")

        let failedPaths = paths("failed-completion-lost")
        let failedStore = OwnerCommandRecordStore(paths: failedPaths, store: FailAtSave(failureIndex: 2, counter: SaveCounter()))
        var failedEnvironment = ProcessInfo.processInfo.environment
        failedEnvironment["FIXTURE_MODE"] = "failure"
        let failingRunner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: executable,
                                               environment: failedEnvironment, home: home)
        let failed = OwnerCommandJournal(store: failedStore).execute(recipeID: "pnpm-store-prune", targetPath: target.path) {
            failingRunner.perform(confirmed: target)
        }
        if case .completionNotSaved(.failure(.actionFailed(17)), _) = failed {
            check(true, "failed command plus completion write failure remains distinguishable")
        } else { fatalError("unexpected failed command result") }
        check(try failedStore.entries().map(\.outcome) == ["started"], "failed command leaves incomplete durable attempt")

        try package()
        let goodStore = OwnerCommandRecordStore(paths: paths("success"))
        let done = OwnerCommandJournal(store: goodStore).execute(recipeID: "pnpm-store-prune", targetPath: target.path) {
            runner.perform(confirmed: target)
        }
        if case .completed(.success, let record) = done { check(record.outcome == "success", "command completion recorded") }
        else { fatalError("unexpected success result") }
        let savedBeforeRefresh = try goodStore.entries()
        check(savedBeforeRefresh.map(\.outcome) == ["started", "success"] && savedBeforeRefresh[1].attemptID == savedBeforeRefresh[0].id,
              "completion durable before caller's refresh boundary")
        print("EVIDENCE simulated refresh begins after both records persisted")
    }
}
