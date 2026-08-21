import Foundation

public enum Action: Equatable, Sendable {
    case skip(reason: String)
    case trash
    case delete
    case notify(reason: String)
}

public struct EvaluatedAction: Equatable, Sendable {
    public let itemID: String
    public let action: Action

    public init(itemID: String, action: Action) {
        self.itemID = itemID
        self.action = action
    }
}

public struct RuleEvaluator: Sendable {
    private let config: Config
    private let now: @Sendable () -> Date
    /// 每个项目配方对应的“活跃窗口内最近有 FSEvents 写活动”的项目根；
    /// 命中则跳过（实时"正在使用"保护）。窗口长度由 recipe.minimumIdleHours 决定。
    private let activeProjectRootsByRecipe: [String: Set<String>]
    /// 每个配方的最短闲置小时数（mtime 判定），未配置时回落 24h。
    private let idleHoursByRecipe: [String: Double]

    public init(
        config: Config,
        now: @escaping @Sendable () -> Date = { Date() },
        activeProjectRootsByRecipe: [String: Set<String>] = [:],
        idleHoursByRecipe: [String: Double] = [:]
    ) {
        self.config = config
        self.now = now
        self.activeProjectRootsByRecipe = activeProjectRootsByRecipe
        self.idleHoursByRecipe = idleHoursByRecipe
    }

    public func evaluate(
        item: ScanItem,
        isProcessRunning: (String?) -> Bool,
        force: Bool = false,
        ignoreAge: Bool = false
    ) -> EvaluatedAction {
        let rule = config.rules.first { $0.recipeID == item.recipeID }
        if config.whitelistPaths.contains(item.path) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "whitelisted"))
        }
        if config.keptItemIDs.contains(item.id) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "kept by user"))
        }
        // 项目配方：父目录（项目根）在配方活跃窗口内最近有写活动 = 正在使用，绝不清理
        if item.recipeID.hasPrefix("project-"),
           !item.paths.isEmpty,
           let activeRoots = activeProjectRootsByRecipe[item.recipeID],
           !Set(item.paths.map {
               URL(fileURLWithPath: $0).deletingLastPathComponent().path
           }).isDisjoint(with: activeRoots) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "project active"))
        }
        if !(rule?.enabled ?? true) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "disabled"))
        }
        switch item.cleanability {
        case .displayOnly:
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "display only"))
        case .trashOnly:
            if force {
                return EvaluatedAction(itemID: item.id, action: .trash)
            }
            return EvaluatedAction(itemID: item.id, action: .notify(reason: "requires user confirmation"))
        case .regenerable:
            break
        }
        switch item.safety {
        case .userConfirm:
            return EvaluatedAction(itemID: item.id, action: .notify(reason: "requires user confirmation"))
        case .requiresQuit:
            if let process = itemProcessName(for: item), isProcessRunning(process) {
                return EvaluatedAction(itemID: item.id, action: .notify(reason: "process running: \(process)"))
            }
        case .safeWhileRunning:
            break
        }
        // 手动清理（force）：忽略年龄/最近修改保护，一律进回收站
        if force {
            switch item.disposition {
            case .none:
                return EvaluatedAction(itemID: item.id, action: .skip(reason: "disposition none"))
            default:
                return EvaluatedAction(itemID: item.id, action: .trash)
            }
        }
        guard let modified = item.lastModified else {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "no modification date"))
        }
        let ageLimitDays = rule?.maxAgeDays ?? recipeDefaultAge(for: item)
        // 紧急清理可跳过年龄/最近修改保护，但保留处置方式与可清理性底线
        guard ignoreAge || CleanabilityRules.isOldEnough(
            lastModified: modified,
            ageLimitDays: ageLimitDays,
            minimumIdleHours: idleHoursByRecipe[item.recipeID] ?? 24,
            now: now()
        ) else {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "too recent"))
        }
        let disposition = rule?.disposition ?? item.disposition
        switch disposition {
        case .trash:
            return EvaluatedAction(itemID: item.id, action: .trash)
        case .deletePermanently:
            return EvaluatedAction(itemID: item.id, action: .delete)
        case .none:
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "disposition none"))
        }
    }

    private func itemProcessName(for item: ScanItem) -> String? {
        switch item.category {
        case .xcode:
            return "Xcode"
        case .simulator:
            return "Simulator"
        default:
            return nil
        }
    }

    private func recipeDefaultAge(for item: ScanItem) -> Int {
        switch item.category {
        case .xcode:
            return item.recipeID == "xctestdevices" ? 3 : 7
        default:
            return 30
        }
    }
}
