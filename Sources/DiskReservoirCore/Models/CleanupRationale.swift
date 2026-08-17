import Foundation

/// 单个可清理项的“为什么建议清理 / 为什么需要确认”说明，
/// 由 UI 负责翻译成用户可见文案。
public struct CleanupRationale: Equatable, Sendable {
    public enum SuggestionReason: Equatable, Sendable {
        /// 可再生：删除后会重新生成或重新下载。
        case regenerable
        /// 模拟器运行时镜像：按最后启动时间判断长期未使用。
        case unusedSimulatorRuntime
        /// 模拟器共享缓存：对应运行时长期未使用。
        case unusedSimulatorSharedCache
        /// 真机调试支持：仅列旧版本，当前调试版本保留。
        case oldDeviceSupport
        /// 模拟器设备数据：不可再生。
        case simulatorDeviceData
        /// 用户数据：仅展示，不清理。
        case userDataOnly
    }

    public enum ConfirmationReason: Equatable, Sendable {
        /// 删除后如需再次使用需要重新下载。
        case reDownload
        /// 需要重新下载，且删除需要管理员权限。
        case reDownloadNeedsAdmin
        /// 下次启动模拟器时自动重建。
        case rebuildsOnBoot
        /// 数据不可再生，删除后需重建设备并重装 App。
        case nonRegenerable
    }

    public let suggestion: SuggestionReason
    public let confirmation: ConfirmationReason?
    /// 最后使用时间（运行时为最后启动时间，其余为目录最新写入时间）。
    public let lastUsed: Date?

    public init(
        suggestion: SuggestionReason,
        confirmation: ConfirmationReason?,
        lastUsed: Date?
    ) {
        self.suggestion = suggestion
        self.confirmation = confirmation
        self.lastUsed = lastUsed
    }

    public static func make(for item: ScanItem) -> CleanupRationale {
        switch item.cleanability {
        case .displayOnly:
            return CleanupRationale(
                suggestion: .userDataOnly,
                confirmation: nil,
                lastUsed: item.lastModified
            )
        case .trashOnly:
            return CleanupRationale(
                suggestion: .simulatorDeviceData,
                confirmation: .nonRegenerable,
                lastUsed: item.lastModified
            )
        case .regenerable:
            break
        }

        let suggestion: SuggestionReason
        let confirmation: ConfirmationReason?
        switch item.recipeID {
        case "simulator-runtimes":
            suggestion = .unusedSimulatorRuntime
            confirmation = .reDownloadNeedsAdmin
        case "simulator-dyld-cache":
            suggestion = .unusedSimulatorSharedCache
            confirmation = .rebuildsOnBoot
        case "xcode-devicesupport":
            suggestion = .oldDeviceSupport
            confirmation = .reDownload
        default:
            suggestion = .regenerable
            confirmation = nil
        }
        return CleanupRationale(
            suggestion: suggestion,
            confirmation: confirmation,
            lastUsed: item.lastModified
        )
    }
}
