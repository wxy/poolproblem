import Foundation

@main struct ReadOnlyRealProbe {
    static func main() throws {
        let home = NSHomeDirectory()
        var environment = ProcessInfo.processInfo.environment
        // Match the minimal PATH observed in the menu bar app. This entry point
        // calls `store path` and Scanner only; it never invokes `store prune`.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let runner = OwnerCommandRunner(recipe: .pnpmStorePrune, environment: environment, home: home)
        switch runner.probe() {
        case .failure(let failure):
            print("probe=failure \(failure)")
            throw failure
        case .success(let target):
            let result = try Scanner().scan(
                recipes: [OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: target)],
                homeDirectory: home
            )
            guard let item = result.items.first(where: {
                $0.recipeID == OwnerCommandRecipe.pnpmStorePrune.id && $0.path == target.path
            }) else { throw CocoaError(.fileNoSuchFile) }
            let display = ScanDisplayPolicy.visibleItems(result.items, recipes: [
                OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: target)
            ])
            print("probe=success")
            print("executable=\(target.executable.replacingOccurrences(of: home, with: "~"))")
            print("store=\(target.path.replacingOccurrences(of: home, with: "~"))")
            print("allocated_bytes=\(item.allocatedBytes)")
            print("visible_above_10_mb=\(!display.isEmpty)")
            print("prune_executed=false")
        }
    }
}
