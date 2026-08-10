import Foundation

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
        case "trash": return string("recipe.trash")
        default: return fallback
        }
    }
}
