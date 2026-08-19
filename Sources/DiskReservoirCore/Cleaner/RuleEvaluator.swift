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
    /// 最近有 FSEvents 写活动的项目根：命中则跳过（实时"正在使用"保护）。
    private let recentlyActiveProjectRoots: Set<String>

    public init(
        config: Config,
        now: @escaping @Sendable () -> Date = { Date() },
        recentlyActiveProjectRoots: Set<String> = []
    ) {
        self.config = config
        self.now = now
        self.recentlyActiveProjectRoots = recentlyActiveProjectRoots
    }

    public func evaluate(
        item: ScanItem,
        isProcessRunning: (String?) -> Bool,
        force: Bool = false
    ) -> EvaluatedAction {
        let rule = config.rules.first { $0.recipeID == item.recipeID }
        if config.whitelistPaths.contains(item.path) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "whitelisted"))
        }
        if config.keptItemIDs.contains(item.id) {
            return EvaluatedAction(itemID: item.id, action: .skip(reason: "kept by user"))
        }
        // 项目配方：父目录（项目根）最近有写活动 = 正在使用，绝不清理
        if item.recipeID.hasPrefix("project-"),
           !item.paths.isEmpty,
           !Set(item.paths.map {
               URL(fileURLWithPath: $0).deletingLastPathComponent().path
           }).isDisjoint(with: recentlyActiveProjectRoots) {
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
        guard CleanabilityRules.isOldEnough(
            lastModified: modified,
            ageLimitDays: ageLimitDays,
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
