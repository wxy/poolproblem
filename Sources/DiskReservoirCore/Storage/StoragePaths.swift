import Foundation

public struct StoragePaths: Sendable {
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }
}
