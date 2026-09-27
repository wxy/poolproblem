import Foundation
import Darwin

/// An owner-command recipe. Its scan entry is observational; only `perform` may mutate it.
public struct OwnerCommandRecipe: Sendable {
    public let id: String
    public let executableName: String
    public let probeArguments: [String]
    public let actionArguments: [String]

    public static let pnpmStorePrune = OwnerCommandRecipe(
        id: "pnpm-store-prune", executableName: "pnpm",
        probeArguments: ["store", "path"], actionArguments: ["store", "prune"]
    )

    public func scanRecipe(target: OwnerCommandTarget) -> Recipe {
        Recipe(
            id: id, name: "pnpm store", category: .packageManager,
            group: .packageManager, safety: .userConfirm,
            disposition: .none, cleanability: .watchOnly,
            defaultAgeDays: 0, minimumSizeMB: 10, processName: nil,
            resolvePaths: { _ in [target.path] }
        )
    }
}

public struct OwnerCommandTarget: Sendable, Equatable {
    public let executable: String
    public let path: String
}

public enum OwnerCommandFailure: Error, Sendable, Equatable {
    case unavailable
    case invalidTarget
    case ambiguousTarget
    case targetChanged
    case probeFailed(Int32)
    case actionFailed(Int32)
    case timedOut
    case launchFailed
}

public struct OwnerCommandOutcome: Sendable {
    public let target: OwnerCommandTarget
    public let capacityDeltaBytes: Int64?
    public let output: String
}

public struct OwnerCommandRunner: Sendable {
    public let recipe: OwnerCommandRecipe
    private let explicitExecutable: String?
    private let environment: [String: String]
    private let home: String
    private let timeout: TimeInterval

    public init(
        recipe: OwnerCommandRecipe,
        executable: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        timeout: TimeInterval = 30
    ) {
        self.recipe = recipe
        self.explicitExecutable = executable
        self.environment = environment
        self.home = home
        self.timeout = timeout
    }

    public func probe() -> Result<OwnerCommandTarget, OwnerCommandFailure> {
        let candidates = locateExecutables()
        guard !candidates.isEmpty else { return .failure(.unavailable) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var selected: OwnerCommandTarget?
        var firstFailure: OwnerCommandFailure?
        for executable in candidates {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return .failure(.timedOut) }
            switch probe(executable: executable, timeLimit: min(8, remaining)) {
            case .success(let target):
                if let selected, selected.path != target.path { return .failure(.ambiguousTarget) }
                if selected == nil { selected = target }
            case .failure(let failure):
                // A timed-out candidate may point to a different store; do not
                // treat a separate successful candidate as unambiguous.
                if failure == .timedOut { return .failure(.timedOut) }
                if firstFailure == nil { firstFailure = failure }
            }
        }
        return selected.map(Result.success) ?? .failure(firstFailure ?? .unavailable)
    }

    private func probe(executable: String, timeLimit: TimeInterval) -> Result<OwnerCommandTarget, OwnerCommandFailure> {
        switch run(executable: executable, arguments: recipe.probeArguments, isProbe: true, timeLimit: timeLimit) {
        case .failure(let failure): return .failure(failure)
        case .success(let result):
            guard result.status == 0 else { return .failure(.probeFailed(result.status)) }
            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            guard lines.count == 1, let path = lines.first,
                  let canonical = validDirectory(path) else { return .failure(.invalidTarget) }
            return .success(OwnerCommandTarget(executable: executable, path: canonical))
        }
    }

    public func perform(confirmed: OwnerCommandTarget) -> Result<OwnerCommandOutcome, OwnerCommandFailure> {
        // Re-run the exact executable and compare the canonical directory just before mutation.
        guard FileManager.default.isExecutableFile(atPath: confirmed.executable) else {
            return .failure(.unavailable)
        }
        switch run(executable: confirmed.executable, arguments: recipe.probeArguments, isProbe: true) {
        case .failure(.timedOut): return .failure(.timedOut)
        case .failure: return .failure(.launchFailed)
        case .success(let check):
            guard check.status == 0 else { return .failure(.probeFailed(check.status)) }
            let lines = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            guard lines.count == 1, let path = lines.first,
                  let canonical = validDirectory(path) else { return .failure(.invalidTarget) }
            guard canonical == confirmed.path else { return .failure(.targetChanged) }
        }
        let url = URL(fileURLWithPath: confirmed.path, isDirectory: true)
        let before = VolumeReader.read(fileURL: url)
        switch run(executable: confirmed.executable, arguments: recipe.actionArguments) {
        case .failure(.timedOut): return .failure(.timedOut)
        case .failure: return .failure(.launchFailed)
        case .success(let action):
            guard action.status == 0 else { return .failure(.actionFailed(action.status)) }
            let after = VolumeReader.read(fileURL: url)
            let delta: Int64? = before.totalBytes > 0 && after.totalBytes == before.totalBytes
                ? after.availableBytes - before.availableBytes : nil
            return .success(OwnerCommandOutcome(target: confirmed, capacityDeltaBytes: delta, output: action.output))
        }
    }

    private func validDirectory(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.contains("\r"),
              !raw.contains("\n"), !raw.contains("/../") else { return nil }
        let canonical = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical != "/", canonical != homePath,
              URL(fileURLWithPath: canonical).pathComponents.count > 2 else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return canonical
    }

    private func locateExecutables() -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/share/pnpm", home + "/Library/pnpm"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            directories += versions.sorted().reversed().map { nvm + "/" + $0 + "/bin" }
        }
        let candidates = explicitExecutable.map { [$0] }
            ?? directories.map { $0 + "/" + recipe.executableName }
        var seen = Set<String>()
        return candidates.filter {
            $0.hasPrefix("/") && seen.insert($0).inserted
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func run(executable: String, arguments: [String], isProbe: Bool = false, timeLimit: TimeInterval? = nil) -> Result<(status: Int32, output: String), OwnerCommandFailure> {
        guard executable.hasPrefix("/"), !executable.contains("\0"),
              !arguments.contains(where: { $0.contains("\0") }) else { return .failure(.launchFailed) }
        var env = environment
        env["HOME"] = home
        if isProbe { env["COREPACK_ENABLE_NETWORK"] = "0" }
        env["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        guard !env.contains(where: { $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }) else {
            return .failure(.launchFailed)
        }
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else { return .failure(.launchFailed) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { close(readFD) }
        var writerOpen = true
        defer { if writerOpen { close(writeFD) } }
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else { return .failure(.launchFailed) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.launchFailed) }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.launchFailed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // PGID 0 means the child's own PID. Darwin establishes it before exec:
        // a failed attribute or file action prevents the owner command from running.
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, home) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addclose(&actions, readFD) == 0,
              posix_spawn_file_actions_addclose(&actions, writeFD) == 0 else { return .failure(.launchFailed) }
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = env.map { strdup($0.key + "=" + $0.value) }
        defer { for value in argv + envp { free(value) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return .failure(.launchFailed) }
        var pid: pid_t = 0
        let spawnStatus = (argv + [nil]).withUnsafeBufferPointer { args in
            (envp + [nil]).withUnsafeBufferPointer { vars in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard spawnStatus == 0 else { return .failure(.launchFailed) }
        close(writeFD)
        writerOpen = false
        let output = OutputBuffer()
        var bytes = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound work per poll even if a producer never stops writing.
            for _ in 0..<32 {
                let count = Darwin.read(readFD, &bytes, bytes.count)
                if count <= 0 { break }
                output.append(Data(bytes.prefix(count)))
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var expired = false
        var observationFailed = false
        while true {
            drain()
            var info = siginfo_t()
            // Leave the leader waitable until after group termination, so its PID
            // cannot be reused and accidentally target an unrelated process group.
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result != 0 {
                if errno == EINTR { continue }
                observationFailed = true
                break
            }
            if info.si_pid == pid { break }
            if ProcessInfo.processInfo.systemUptime - started >= (timeLimit ?? timeout) {
                expired = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Also clean descendants when a wrapper exits before them. SIGKILL cannot
        // be ignored; do not rely on the wrapper forwarding termination signals.
        let killed = kill(-pid, SIGKILL)
        let killError = errno
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        drain()
        // Darwin can return EPERM for a group containing only the zombie
        // leader. Accept that only after reaping and confirming the group is gone.
        let groupGone = kill(-pid, 0) == -1 && errno == ESRCH
        guard (killed == 0 || killError == ESRCH || groupGone), waited == pid, !observationFailed else {
            return .failure(.launchFailed)
        }
        if expired { return .failure(.timedOut) }
        let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return .success((exitStatus, output.string))
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) }
        lock.unlock()
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct OwnerCommandRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let recipeID: String
    public let targetPath: String
    public let outcome: String
    public let capacityDeltaBytes: Int64?
    /// Links a completion to its persisted attempt. Nil in older records and attempts.
    public let attemptID: UUID?

    public init(recipeID: String, targetPath: String, outcome: String, capacityDeltaBytes: Int64?, attemptID: UUID? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.recipeID = recipeID
        self.targetPath = targetPath
        self.outcome = outcome
        self.capacityDeltaBytes = capacityDeltaBytes
        self.attemptID = attemptID
    }
}

public enum OwnerCommandJournalResult: Sendable {
    case startNotSaved
    case completionNotSaved(Result<OwnerCommandOutcome, OwnerCommandFailure>, OwnerCommandRecord)
    case completed(Result<OwnerCommandOutcome, OwnerCommandFailure>, OwnerCommandRecord)
}

/// Runs a destructive owner command only after its attempt is persisted.
/// Returns as soon as completion persistence is attempted, before UI refresh work.
public struct OwnerCommandJournal: Sendable {
    private let store: OwnerCommandRecordStore

    public init(store: OwnerCommandRecordStore) { self.store = store }

    public func execute(
        recipeID: String, targetPath: String,
        action: () -> Result<OwnerCommandOutcome, OwnerCommandFailure>
    ) -> OwnerCommandJournalResult {
        let attempt = OwnerCommandRecord(recipeID: recipeID, targetPath: targetPath,
                                         outcome: "started", capacityDeltaBytes: nil)
        do { try store.append(attempt) }
        catch { return .startNotSaved }

        let result = action()
        let outcome: String
        let delta: Int64?
        switch result {
        case .success(let success): outcome = "success"; delta = success.capacityDeltaBytes
        case .failure(let failure): outcome = String(describing: failure); delta = nil
        }
        let completion = OwnerCommandRecord(recipeID: recipeID, targetPath: targetPath,
                                            outcome: outcome, capacityDeltaBytes: delta,
                                            attemptID: attempt.id)
        do { try store.append(completion) }
        catch { return .completionNotSaved(result, attempt) }
        return .completed(result, completion)
    }
}

public struct OwnerCommandRecordStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func entries() throws -> [OwnerCommandRecord] {
        try store.load([OwnerCommandRecord].self, from: paths.baseURL.appendingPathComponent("owner-command-log.json")) ?? []
    }

    public func append(_ entry: OwnerCommandRecord) throws {
        let url = paths.baseURL.appendingPathComponent("owner-command-log.json")
        var all = try entries()
        all.append(entry)
        try store.save(all, to: url)
    }
}
