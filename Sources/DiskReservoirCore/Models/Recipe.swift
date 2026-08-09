public struct Recipe: Sendable {
    public let id: String
    public let name: String
    public let category: Category
    public let safety: SafetyLevel
    public let disposition: CleanDisposition
    public let defaultAgeDays: Int
    public let minimumSizeMB: Double
    public let processName: String?
    public let resolvePaths: @Sendable (StoragePaths) -> [String]

    public init(
        id: String,
        name: String,
        category: Category,
        safety: SafetyLevel,
        disposition: CleanDisposition,
        defaultAgeDays: Int,
        minimumSizeMB: Double,
        processName: String?,
        resolvePaths: @escaping @Sendable (StoragePaths) -> [String]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.safety = safety
        self.disposition = disposition
        self.defaultAgeDays = defaultAgeDays
        self.minimumSizeMB = minimumSizeMB
        self.processName = processName
        self.resolvePaths = resolvePaths
    }
}
