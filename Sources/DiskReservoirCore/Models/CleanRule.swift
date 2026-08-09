public struct CleanRule: Codable, Equatable, Sendable {
    public let recipeID: String
    public var enabled: Bool
    public var maxAgeDays: Int?
    public var minimumSizeMB: Double?
    public var disposition: CleanDisposition?

    public init(
        recipeID: String,
        enabled: Bool,
        maxAgeDays: Int? = nil,
        minimumSizeMB: Double? = nil,
        disposition: CleanDisposition? = nil
    ) {
        self.recipeID = recipeID
        self.enabled = enabled
        self.maxAgeDays = maxAgeDays
        self.minimumSizeMB = minimumSizeMB
        self.disposition = disposition
    }
}
