import Foundation

/// 配方的产品/生态分组（展示与未来协调的维度）。
/// 分组不改变各配方自己的规则，只负责组织：同一组内的配方属于同一工具链
/// 或同一生态（如 Xcode 与其模拟器、Node.js 项目族）。
public enum RecipeGroup: String, Codable, CaseIterable, Sendable {
    /// Xcode 及其模拟器工具链（模拟器在 Xcode 中使用，归入同组）。
    case xcode
    /// Node.js 项目：node_modules / 项目构建产物，发现的项目不断加入其作用域。
    case nodejs
    /// 包管理器全局缓存（npm/pnpm/uv/CocoaPods/Homebrew 等）。
    case packageManager
    /// 系统 / 通用（应用缓存、本应用回收站批次、废纸篓）。
    case system

    /// 组级进程守卫：任一进程运行中，整组不参与自动清理
    /// （如 Xcode 运行中，Xcode 及其模拟器整组暂停）。
    public var guardProcessNames: [String] {
        switch self {
        case .xcode: return ["Xcode", "Simulator"]
        default: return []
        }
    }

    /// 组级规则在 Config.rules 中的稳定标识（如 "group:xcode"）。
    public var ruleID: String { "group:" + rawValue }
}
