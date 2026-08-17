import Foundation
import DiskReservoirCore

/// 本地化辅助：英文为源语言，简体中文提供翻译（Localizable.xcstrings）
enum Localized {
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    static func string(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        String(format: String(localized: key), arguments: args)
    }

    /// 按配方 id 返回本地化显示名；未知配方回退到 Core 提供的名称
    static func recipeName(_ recipeID: String, fallback: String) -> String {
        switch recipeID {
        case "xctestdevices": return string("recipe.xctestdevices")
        case "deriveddata": return string("recipe.deriveddata")
        case "xcode-archives": return string("recipe.xcode-archives")
        case "xcode-docscache": return string("recipe.xcode-docscache")
        case "core-simulator-devices": return string("recipe.core-simulator-devices")
        case "npm-cache": return string("recipe.npm-cache")
        case "pnpm-store": return string("recipe.pnpm-store")
        case "uv-cache": return string("recipe.uv-cache")
        case "cocoapods-cache": return string("recipe.cocoapods-cache")
        case "homebrew-cache": return string("recipe.homebrew-cache")
        case "library-caches": return string("recipe.library-caches")
        case "xcode-preview-cache": return string("recipe.xcode-preview-cache")
        case "xcode-devicesupport": return string("recipe.xcode-devicesupport")
        case "simulator-runtimes": return string("recipe.simulator-runtimes")
        case "simulator-dyld-cache": return string("recipe.simulator-dyld-cache")
        case "trash": return string("recipe.trash")
        default: return fallback
        }
    }

    /// “为什么建议清理”文案
    static func suggestionText(_ reason: CleanupRationale.SuggestionReason) -> String {
        switch reason {
        case .regenerable:
            return string("rationale.regenerable")
        case .unusedSimulatorRuntime:
            return string("rationale.simulator_runtime")
        case .unusedSimulatorSharedCache:
            return string("rationale.simulator_shared_cache")
        case .oldDeviceSupport:
            return string("rationale.old_device_support")
        case .simulatorDeviceData:
            return string("rationale.simulator_device_data")
        case .userDataOnly:
            return string("rationale.user_data_only")
        }
    }

    /// “为什么需要确认”文案
    static func confirmationText(_ reason: CleanupRationale.ConfirmationReason) -> String {
        switch reason {
        case .reDownload:
            return string("rationale.confirm.redownload")
        case .reDownloadNeedsAdmin:
            return string("rationale.confirm.redownload_admin")
        case .rebuildsOnBoot:
            return string("rationale.confirm.rebuilds_on_boot")
        case .nonRegenerable:
            return string("rationale.confirm.non_regenerable")
        }
    }
}
