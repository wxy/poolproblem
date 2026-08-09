public enum SafetyLevel: String, Codable, CaseIterable, Sendable {
    case safeWhileRunning
    case requiresQuit
    case userConfirm
}
