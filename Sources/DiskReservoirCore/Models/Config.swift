public struct Config: Codable, Equatable, Sendable {
    public var waterlineGB: Double
    public var rules: [CleanRule]
    public var whitelistPaths: [String]
    public var enabledRecipes: Set<String>
    public var cloneRatios: [String: Double]
    public var keptItemIDs: Set<String>

    public static let `default` = Config(
        waterlineGB: 30,
        rules: [],
        whitelistPaths: [],
        enabledRecipes: [],
        cloneRatios: [:],
        keptItemIDs: []
    )

    public init(
        waterlineGB: Double,
        rules: [CleanRule],
        whitelistPaths: [String],
        enabledRecipes: Set<String>,
        cloneRatios: [String: Double] = [:],
        keptItemIDs: Set<String> = []
    ) {
        self.waterlineGB = waterlineGB
        self.rules = rules
        self.whitelistPaths = whitelistPaths
        self.enabledRecipes = enabledRecipes
        self.cloneRatios = cloneRatios
        self.keptItemIDs = keptItemIDs
    }
}
