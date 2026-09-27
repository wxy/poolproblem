import Foundation

/// Protects owner-managed stores from deletion through a different recipe,
/// including old aggregate snapshots and symlink aliases of an ancestor.
public enum OwnerManagedPathGuard {
    public static func overlaps(_ path: String, storePath: String) -> Bool {
        let candidate = canonical(path)
        let store = canonical(storePath)
        return candidate == store
            || candidate.hasPrefix(store + "/")
            || store.hasPrefix(candidate + "/")
    }

    public static func mayDelete(
        path: String,
        recipeID: String,
        probe: Result<OwnerCommandTarget, OwnerCommandFailure>,
        homeDirectory: String = NSHomeDirectory(),
        knownStorePaths: [String] = [],
        historyOverflowed: Bool = false
    ) -> Bool {
        guard recipeID != OwnerCommandRecipe.pnpmStorePrune.id else { return false }
        // At least one older target was evicted. Its path is unknown, so no
        // raw path can be proven disjoint from the complete owner history.
        if historyOverflowed { return false }
        if knownStorePaths.contains(where: { overlaps(path, storePath: $0) }) {
            return false
        }
        if isRecognizablePnpmLocation(path, homeDirectory: homeDirectory) {
            return false
        }
        switch probe {
        case .success(let target):
            return !overlaps(path, storePath: target.path)
        case .failure(.unavailable):
            // No executable is detectable. Preserve unrelated cleanup; an
            // arbitrary orphan store without a saved target is unknowable.
            return true
        case .failure:
            // User-added package-manager roots may be a store or its parent;
            // without a trustworthy probe, their raw deletion is unsafe.
            if recipeID == PackageManagerRecipes.customID { return false }
            // A present but broken executable cannot establish where its
            // store sits; broad package/cache roots fail closed.
            if recipeID == PackageManagerRecipes.familyID || recipeID == "library-caches" {
                return false
            }
            return true
        }
    }

    public static func isRecognizablePnpmLocation(
        _ path: String, homeDirectory: String
    ) -> Bool {
        let roots = [
            "Library/pnpm", "Library/Caches/pnpm",
            ".local/share/pnpm", ".cache/pnpm", ".pnpm-store",
        ].map { homeDirectory + "/" + $0 }
        return roots.contains { overlaps(path, storePath: $0) }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
