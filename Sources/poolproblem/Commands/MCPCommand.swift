import ArgumentParser
import DiskReservoirCore
import Foundation

/// 把现有 CLI 能力包装成 MCP stdio server：
///   poolproblem mcp
///
/// 支持的 MCP tools：scan、suggest、clean、status。
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: CLILocalized.string("mcp.abstract")
    )

    func run() throws {
        let server = MCPServer()
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(response)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }
}

private final class MCPServer {
    func handle(_ line: String) -> Data? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return nil
        }
        let id = object["id"]

        switch method {
        case "initialize":
            return response(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": "poolproblem",
                    "version": "1.1.0",
                ],
            ])

        case "notifications/initialized":
            return nil

        case "tools/list":
            return response(id: id, result: ["tools": Self.tools])

        case "tools/call":
            guard let params = object["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Invalid tool call")
            }
            do {
                let text = try runTool(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
                return response(id: id, result: [
                    "content": [
                        ["type": "text", "text": text],
                    ],
                    "isError": false,
                ])
            } catch {
                return response(id: id, result: [
                    "content": [
                        ["type": "text", "text": error.localizedDescription],
                    ],
                    "isError": true,
                ])
            }

        case "ping":
            return response(id: id, result: [:])

        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static var tools: [[String: Any]] {
        [
            [
                "name": "scan",
                "description": "Scan all disk cleanup recipes and save a snapshot.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                ],
            ],
            [
                "name": "suggest",
                "description": "List currently cleanable items with recommended actions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                ],
            ],
            [
                "name": "clean",
                "description": "Clean according to the current waterline and rules. Use dryRun to preview only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "dryRun": [
                            "type": "boolean",
                            "description": "Preview what would be cleaned without deleting anything.",
                        ],
                    ],
                ],
            ],
            [
                "name": "status",
                "description": "Read the latest snapshot, prediction, and recent cleanup log.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                ],
            ],
        ]
    }

    private func runTool(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "scan":
            return try scanJSON()
        case "suggest":
            return try suggestJSON()
        case "clean":
            let dryRun = arguments["dryRun"] as? Bool ?? false
            return try cleanJSON(dryRun: dryRun)
        case "status":
            return try statusJSON()
        default:
            throw MCPError.unknownTool(name)
        }
    }

    private func scanJSON() throws -> String {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let result = try DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios).scan(
            recipes: RecipeRegistry.builtIn(),
            homeDirectory: NSHomeDirectory()
        )
        try SnapshotStore(paths: paths).append(Snapshot(volume: result.volume, items: result.items))
        return string(try JSONOutput.scan(result: result))
    }

    private func suggestJSON() throws -> String {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let result = try DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios).scan(
            recipes: RecipeRegistry.builtIn(),
            homeDirectory: NSHomeDirectory()
        )
        let evaluator = RuleEvaluator(config: config)
        let suggestions = result.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
            let action = evaluator.evaluate(item: item) { name in
                name.map { PGrepProcessInspector().isRunning($0) } ?? false
            }
            switch action.action {
            case .skip:
                return nil
            default:
                return (item, action)
            }
        }
        return string(try JSONOutput.suggestions(suggestions))
    }

    private func cleanJSON(dryRun: Bool) throws -> String {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let result = try DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios).scan(
            recipes: RecipeRegistry.builtIn(),
            homeDirectory: NSHomeDirectory()
        )
        let evaluator = RuleEvaluator(config: config)
        let waterlineBytes = Int64(config.waterlineGB * 1_000_000_000)
        let outcome: CleanOutcome
        if dryRun {
            let suggestions = result.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
                let action = evaluator.evaluate(item: item) { name in
                    name.map { PGrepProcessInspector().isRunning($0) } ?? false
                }
                switch action.action {
                case .skip, .notify:
                    return nil
                default:
                    return (item, action)
                }
            }
            outcome = CleanOutcome(
                entries: suggestions.map { entry in
                    let disposition: CleanDisposition
                    if case .trash = entry.1.action {
                        disposition = .trash
                    } else {
                        disposition = .deletePermanently
                    }
                    return CleanLogEntry(
                        id: UUID(),
                        timestamp: Date(),
                        itemIDs: [entry.0.id],
                        freedBytes: entry.0.reclaimableBytes,
                        disposition: disposition
                    )
                },
                freedBytes: suggestions.reduce(0) { $0 + $1.0.reclaimableBytes },
                actualFreedBytes: 0,
                stillBelowWaterline: result.volume.availableBytes < waterlineBytes
            )
        } else {
            outcome = try Cleaner(
                evaluator: evaluator,
                deleter: FileManagerFileDeleter(),
                inspector: PGrepProcessInspector(),
                logStore: CleanLogStore(paths: paths)
            ).run(
                scan: result,
                config: config,
                waterlineBytes: waterlineBytes
            )
        }
        return string(try JSONOutput.clean(outcome: outcome))
    }

    private func statusJSON() throws -> String {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let snapshots = try SnapshotStore(paths: paths).snapshots()
        let log = try CleanLogStore(paths: paths).entries()
        let prediction = FullPrediction().daysUntilFull(
            snapshots: snapshots,
            waterlineBytes: Int64(config.waterlineGB * 1_000_000_000)
        )
        return string(try JSONOutput.status(snapshots: snapshots, log: log, prediction: prediction))
    }

    private func response(id: Any?, result: [String: Any]) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id {
            payload["id"] = id
        }
        return data(payload)
    }

    private func error(id: Any?, code: Int, message: String) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        if let id {
            payload["id"] = id
        }
        return data(payload)
    }

    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private func string(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

private enum MCPError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}
