import Testing
import Foundation

@Test func cliScanOutputsJSON() throws {
    let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDir) }
    setenv("POOLPROBLEM_DATA_DIR", dataDir.path, 1)
    defer { unsetenv("POOLPROBLEM_DATA_DIR") }

    let output = try runCLI(arguments: ["scan", "--json"])
    let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
    #expect(object?["version"] as? Int == 1)
    #expect(object?["volume"] is [String: Any])
    #expect(object?["items"] is [[String: Any]])
}

@Test func cliStatusOutputsJSONWithoutSnapshots() throws {
    let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-cli-status-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDir) }
    setenv("POOLPROBLEM_DATA_DIR", dataDir.path, 1)
    defer { unsetenv("POOLPROBLEM_DATA_DIR") }

    let output = try runCLI(arguments: ["status", "--json"])
    let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
    #expect(object?["version"] as? Int == 1)
    #expect(object?["snapshotCount"] as? Int == 0)
}

private func runCLI(arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = productsDirectory.appendingPathComponent("poolproblem")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return pipe.fileHandleForReading.readDataToEndOfFile()
}

private var productsDirectory: URL {
    // Tests/PoolProblemCLITests/CLIEndToEndTests.swift → 上溯 3 级到包根目录
    let fileURL = URL(fileURLWithPath: #filePath)
    let packageRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
}
