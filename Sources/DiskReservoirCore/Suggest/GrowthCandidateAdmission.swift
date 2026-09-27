import Foundation

/// Historical suggestions are untrusted metadata. Only an existing project
/// directory may enter the manual-only project recipe after explicit review.
public enum GrowthCandidateAdmission {
    public static func canDisplay(_ candidate: CandidateRecipe) -> Bool {
        guard candidate.recipeID == RecipeSuggester.projectFamilyID,
              candidate.samplePath != "/",
              candidate.samplePath != NSHomeDirectory(),
              GrowthPathStatus.probe(candidate.samplePath) == .present else { return false }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.samplePath, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        if DevDirectoryDetector.detect(path: candidate.samplePath) != nil { return true }
        // Grouped proposals point at a parent of several projects. Recheck
        // the listed children instead of trusting a stale discovery result.
        return candidate.childNames.contains { child in
            guard child != ".", child != "..", !child.contains("/") else { return false }
            return DevDirectoryDetector.detect(
                path: URL(fileURLWithPath: candidate.samplePath)
                    .appendingPathComponent(child, isDirectory: true).path
            ) != nil
        }
    }

    public static func canAccept(_ candidate: CandidateRecipe) -> Bool {
        candidate.status == .pending && canDisplay(candidate)
    }
}
