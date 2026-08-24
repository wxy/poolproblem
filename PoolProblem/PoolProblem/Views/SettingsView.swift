import SwiftUI
import AppKit
import DiskReservoirCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    let service: AppService

    @State private var config: Config = .default
    @State private var expertMode = false
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var newWhitelistPath = ""
    @State private var newProtectedChild = ""
    @State private var hasFullDiskAccess = false
    @State private var settingsTab = 0
    @State private var expandedRecipeIDs: Set<String> = []
    @State private var expandedGroups: Set<RecipeGroup> = []
    @State private var cleanStats: [String: (count: Int, bytes: Int64)] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $settingsTab) {
                Text(Localized.string("settings.tab_general")).tag(0)
                Text(Localized.string("settings.tab_recipes")).tag(1)
                Text(Localized.string("settings.tab_protection")).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Form {
                if settingsTab == 0 {
                    generalSections
                }
                if settingsTab == 1 {
                    recipesSections
                }
                if settingsTab == 2 {
                    protectionSections
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            config = service.loadConfig()
            expertMode = UserDefaults.standard.bool(forKey: "expertMode")
            cleanStats = service.cleanStatsByRecipe()
            Task { hasFullDiskAccess = await PermissionService.hasFullDiskAccess() }
        }
        // 从系统设置返回（应用被激活）时自动重新检测权限
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { hasFullDiskAccess = await PermissionService.hasFullDiskAccess() }
        }
        .onChange(of: expertMode) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "expertMode")
        }
        .onChange(of: config) { _, newValue in
            service.saveConfig(newValue)
        }
    }

    // MARK: - 常规

    @ViewBuilder
    private var generalSections: some View {
        Section(Localized.string("settings.waterline_section")) {
            HStack {
                Text(Localized.string("settings.waterline_label"))
                Slider(value: waterlineBinding, in: 10...100, step: 5)
                Text(verbatim: "\(Int(config.waterlineGB)) GB")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }

        Section(Localized.string("settings.mode_section")) {
            Picker(Localized.string("settings.mode"), selection: $expertMode) {
                Text(Localized.string("settings.mode_foolproof")).tag(false)
                Text(Localized.string("settings.mode_expert")).tag(true)
            }
            .pickerStyle(.segmented)
        }

        Section(Localized.string("settings.minimum_clean_size_section")) {
            HStack {
                Text(Localized.string("settings.minimum_clean_size_label"))
                Spacer()
                Stepper("", value: Binding(
                    get: { config.minimumCleanItemMB },
                    set: { config.minimumCleanItemMB = $0 }
                ), in: 100...5000, step: 100)
                .labelsHidden()
                Text(verbatim: "\(Int(config.minimumCleanItemMB)) MB")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
            Text(Localized.string("settings.minimum_clean_size_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(Localized.string("settings.permission_section")) {
            HStack {
                Image(systemName: hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                Text(hasFullDiskAccess
                     ? Localized.string("settings.permission_granted")
                     : Localized.string("settings.permission_needed"))
                Spacer()
                if !hasFullDiskAccess {
                    Button(Localized.string("settings.open_settings")) { PermissionService.openSystemSettings() }
                        .cursorPointingHand()
                    Button(Localized.string("settings.recheck")) {
                        Task {
                            PermissionService.resetCache()
                            hasFullDiskAccess = await PermissionService.hasFullDiskAccess()
                        }
                    }
                    .cursorPointingHand()
                }
            }
        }

        Section(Localized.string("settings.general_section")) {
            Toggle(Localized.string("settings.launch_at_login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    try? LaunchAtLoginService.setEnabled(newValue)
                }
            Toggle(Localized.string("settings.auto_empty_batches"), isOn: Binding(
                get: { config.autoEmptyOwnTrashBatches },
                set: { config.autoEmptyOwnTrashBatches = $0 }
            ))
            Text(Localized.string("settings.auto_empty_batches_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 配方

    @ViewBuilder
    private var recipesSections: some View {
        if expertMode {
            let packageManagerRecipe = PackageManagerRecipes.make(
                extraRoots: config.packageManagerCacheRoots,
                homeDirectory: NSHomeDirectory()
            )
            let projectRecipes = ProjectRecipes.make(
                devRoots: config.devRoots,
                homeDirectory: NSHomeDirectory()
            )
            let allRecipes = RecipeRegistry.builtIn()
                + [packageManagerRecipe]
                + projectRecipes

            // 概览：一眼看到启用状态，避免整页展开造成的信息过载
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(overviewText(allRecipes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 每组一个可折叠分区：组头 = 图标 + 组名 + 配方数 + 组开关
            ForEach(RecipeGroup.allCases, id: \.self) { group in
                let groupRecipes = allRecipes.filter { $0.group == group }
                if !groupRecipes.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            groupHeader(group, recipes: groupRecipes)
                            if expandedGroups.contains(group) {
                                VStack(alignment: .leading, spacing: 8) {
                                    scopeRows(for: group)
                                    ForEach(groupRecipes, id: \.id) { recipe in
                                        recipeRow(recipe)
                                    }
                                }
                                .padding(.leading, 18)
                                .padding(.top, 6)
                            }
                        }
                    }
                }
            }

            pendingCandidatesSection
        } else {
            expertModeHint
        }
    }

    // MARK: - 保护与排除

    @ViewBuilder
    private var protectionSections: some View {
        Section(Localized.string("settings.whitelist_section")) {
            ForEach(config.whitelistPaths, id: \.self) { path in
                HStack {
                    Text(path).font(.caption).lineLimit(1)
                    Spacer()
                    Button(Localized.string("common.remove")) {
                        config.whitelistPaths.removeAll { $0 == path }
                    }
                    .cursorPointingHand()
                }
            }
            HStack {
                TextField(Localized.string("settings.path_placeholder"), text: $newWhitelistPath)
                    .textFieldStyle(.roundedBorder)
                Button(Localized.string("common.add")) {
                    let trimmed = newWhitelistPath.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !config.whitelistPaths.contains(trimmed) {
                        config.whitelistPaths.append(trimmed)
                    }
                    newWhitelistPath = ""
                }
                .disabled(newWhitelistPath.trimmingCharacters(in: .whitespaces).isEmpty)
                .cursorPointingHand(enabled: !newWhitelistPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        Section(Localized.string("settings.protected_children_section")) {
            ForEach(config.protectedCacheChildren, id: \.self) { name in
                HStack {
                    Text(name).font(.caption).lineLimit(1)
                    if Config.defaultProtectedCacheChildren.contains(name) {
                        Text(Localized.string("settings.builtin"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                    }
                    Spacer()
                    if !Config.defaultProtectedCacheChildren.contains(name) {
                        Button(Localized.string("common.remove")) {
                            config.protectedCacheChildren.removeAll { $0 == name }
                        }
                        .cursorPointingHand()
                    }
                }
            }
            HStack {
                TextField(Localized.string("settings.path_placeholder"), text: $newProtectedChild)
                    .textFieldStyle(.roundedBorder)
                Button(Localized.string("common.add")) {
                    let trimmed = newProtectedChild.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !config.protectedCacheChildren.contains(trimmed) {
                        config.protectedCacheChildren.append(trimmed)
                    }
                    newProtectedChild = ""
                }
                .disabled(newProtectedChild.trimmingCharacters(in: .whitespaces).isEmpty)
                .cursorPointingHand(
                    enabled: !newProtectedChild.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            Text(Localized.string("settings.protected_children_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(Localized.string("settings.kept_section")) {
            if service.keptItemNames().isEmpty {
                Text(Localized.string("settings.no_kept"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.keptItemNames(), id: \.id) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.caption)
                        Spacer()
                        Button(Localized.string("common.remove")) {
                            service.unkeepItem(entry.id)
                        }
                        .cursorPointingHand()
                    }
                }
            }
        }
    }

    // MARK: - 配方行（路径默认折叠）

    @ViewBuilder
    private func recipeRow(_ recipe: Recipe) -> some View {
        let enabled = isEnabled(recipe) && groupEnabled(recipe.group)
        let expanded = expandedRecipeIDs.contains(recipe.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { toggleRecipe(recipe.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: recipeIcon(recipe))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(Localized.recipeName(recipe.id, fallback: recipe.name))
                            .lineLimit(1)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursorPointingHand()
                Spacer()
                Text(Localized.string("settings.keep_days", age(recipe)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { age(recipe) },
                    set: { setAge(recipe, $0) }
                ), in: 1...365)
                .labelsHidden()
                Toggle("", isOn: Binding(
                    get: { isEnabled(recipe) },
                    set: { setEnabled(recipe, $0) }
                ))
                .labelsHidden()
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    cleanStatsLine(recipe)
                    ForEach(recipePaths(recipe), id: \.self) { path in
                        recipePathRow(path)
                    }
                }
                .padding(.leading, 26)
                .padding(.bottom, 4)
            }
        }
    }

    private func toggleRecipe(_ id: String) {
        if expandedRecipeIDs.contains(id) {
            expandedRecipeIDs.remove(id)
        } else {
            expandedRecipeIDs.insert(id)
        }
    }

    private var waterlineBinding: Binding<Double> {
        Binding(
            get: { config.waterlineGB },
            set: { config.waterlineGB = $0 }
        )
    }

    private func rule(for recipe: Recipe) -> CleanRule? {
        config.rules.first { $0.recipeID == recipe.id }
    }

    private func isEnabled(_ recipe: Recipe) -> Bool {
        rule(for: recipe)?.enabled ?? true
    }

    private func age(_ recipe: Recipe) -> Int {
        rule(for: recipe)?.maxAgeDays ?? recipe.defaultAgeDays
    }

    private func setEnabled(_ recipe: Recipe, _ value: Bool) {
        upsertRule(CleanRule(recipeID: recipe.id, enabled: value, maxAgeDays: age(recipe)))
    }

    private func setAge(_ recipe: Recipe, _ value: Int) {
        upsertRule(CleanRule(recipeID: recipe.id, enabled: isEnabled(recipe), maxAgeDays: value))
    }

    private func upsertRule(_ newRule: CleanRule) {
        var rules = config.rules.filter { $0.recipeID != newRule.recipeID }
        rules.append(newRule)
        config.rules = rules
    }

    // MARK: - 组级规则（总开关；组内闲置天数对规则差异大的配方无意义，已移除）

    private func groupRule(_ group: RecipeGroup) -> CleanRule? {
        config.rules.first { $0.recipeID == group.ruleID }
    }

    private func groupEnabled(_ group: RecipeGroup) -> Bool {
        groupRule(group)?.enabled ?? true
    }

    private func setGroupEnabled(_ group: RecipeGroup, _ value: Bool) {
        upsertRule(CleanRule(
            recipeID: group.ruleID,
            enabled: value,
            maxAgeDays: nil
        ))
    }

    // MARK: - 组卡片（组头 / 展开 / 作用域）

    private func toggleGroup(_ group: RecipeGroup) {
        if expandedGroups.contains(group) {
            expandedGroups.remove(group)
        } else {
            expandedGroups.insert(group)
        }
    }

    private func groupEnabledBinding(_ group: RecipeGroup) -> Binding<Bool> {
        Binding(
            get: { groupEnabled(group) },
            set: { setGroupEnabled(group, $0) }
        )
    }

    private func groupHeader(_ group: RecipeGroup, recipes: [Recipe]) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggleGroup(group) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: groupIcon(group))
                        .foregroundStyle(
                            groupEnabled(group)
                                ? Color.secondary
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                    Text(Localized.recipeGroupName(group))
                        .fontWeight(.medium)
                        .foregroundStyle(groupEnabled(group) ? Color.primary : Color.secondary)
                    Text(Localized.string("settings.recipes_count", recipes.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: expandedGroups.contains(group) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursorPointingHand()
            Spacer()
            Toggle("", isOn: groupEnabledBinding(group))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func groupIcon(_ group: RecipeGroup) -> String {
        switch group {
        case .xcode: return "chevron.left.forwardslash.chevron.right"
        case .nodejs: return "cube.fill"
        case .packageManager: return "shippingbox.fill"
        case .system: return "gearshape.fill"
        }
    }

    private func recipeIcon(_ recipe: Recipe) -> String {
        switch recipe.category {
        case .xcode: return "hammer.fill"
        case .simulator: return "iphone.gen3"
        case .packageManager: return "shippingbox.fill"
        case .project: return "cube.fill"
        case .common: return "folder.fill"
        case .custom: return "tag.fill"
        }
    }

    /// 组作用域：用户通过增长洞察纳入监控的目录（属于该组的配方作用域）。
    @ViewBuilder
    private func scopeRows(for group: RecipeGroup) -> some View {
        switch group {
        case .nodejs:
            if !config.devRoots.isEmpty {
                Text(Localized.string("settings.devroots_section"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(config.devRoots, id: \.self) { path in
                    scopePathRow(path) {
                        service.removeDevRoot(path)
                        config.devRoots.removeAll { $0 == path }
                    }
                }
            }
        case .packageManager:
            if !config.packageManagerCacheRoots.isEmpty {
                Text(Localized.string("settings.cache_roots_section"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(config.packageManagerCacheRoots, id: \.self) { path in
                    scopePathRow(path) {
                        service.removePackageManagerCacheRoot(path)
                        config.packageManagerCacheRoots.removeAll { $0 == path }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func scopePathRow(_ path: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .cursorPointingHand()
            .help(Localized.string("common.remove"))
        }
    }

    // MARK: - 概览 / 待采纳建议 / 非专家模式提示

    private func overviewText(_ recipes: [Recipe]) -> String {
        let enabled = recipes.filter { isEnabled($0) && groupEnabled($0.group) }.count
        let pausedGroups = Set(recipes.map(\.group))
            .filter { !groupEnabled($0) }
            .count
        return Localized.string("settings.recipes_overview", enabled, recipes.count, pausedGroups)
    }

    @ViewBuilder
    private var pendingCandidatesSection: some View {
        let pending = state.candidateRecipes.filter { $0.status == .pending }
        if !pending.isEmpty {
            Section(Localized.string("settings.candidates_section")) {
                ForEach(pending) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.pattern)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(candidateRuleText(candidate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(Localized.string("candidate.accept")) {
                            service.acceptCandidate(id: candidate.id)
                        }
                        .cursorPointingHand()
                        Button(Localized.string("candidate.dismiss")) {
                            service.dismissCandidate(id: candidate.id)
                        }
                        .cursorPointingHand()
                    }
                }
            }
        }
    }

    /// 采纳后纳入的现有配方与处理规则（与增长洞察一致）。
    private func candidateRuleText(_ candidate: CandidateRecipe) -> String {
        let name = Localized.recipeName(candidate.recipeID, fallback: candidate.recipeName)
        let safety = candidate.suggestedSafety == .safeWhileRunning
            ? Localized.string("candidate.safety_safe")
            : Localized.string("candidate.safety_confirm")
        let disposition: String
        switch candidate.suggestedDisposition {
        case .trash:
            disposition = Localized.string("candidate.disposition_trash")
        case .deletePermanently:
            disposition = Localized.string("candidate.disposition_permanent")
        case .none:
            disposition = Localized.string("candidate.disposition_monitor")
        }
        return Localized.string("candidate.adds_to_recipe", name, safety, disposition)
    }

    @ViewBuilder
    private var expertModeHint: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(Localized.string("settings.recipes_expert_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(Localized.string("settings.recipes_expert_button")) {
                    settingsTab = 0
                    expertMode = true
                }
                .cursorPointingHand()
            }
        }
    }

    /// 配方解析出的具体路径（可能为空：路径不存在时配方不生效）。
    private func recipePaths(_ recipe: Recipe) -> [String] {
        recipe.resolvePaths(StoragePaths(homeDirectory: NSHomeDirectory()))
    }

    /// 该配方在清理日志中的累计执行次数与清理字节。
    @ViewBuilder
    private func cleanStatsLine(_ recipe: Recipe) -> some View {
        if let stats = cleanStats[recipe.id], stats.count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Localized.string(
                    "settings.recipe_clean_stats",
                    stats.count,
                    Format.bytes(stats.bytes)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 路径行：文件夹图标 + 路径文本。存在的路径可点击打开 Finder；
    /// 不存在的路径不可点击，用删除线区分。
    @ViewBuilder
    private func recipePathRow(_ path: String) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            Button {
                FinderReveal.reveal(path)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .cursorPointingHand()
            .help(path)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(Localized.string("settings.path_missing"))
        }
    }
}
