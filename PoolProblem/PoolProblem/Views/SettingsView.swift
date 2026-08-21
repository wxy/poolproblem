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
            Section(Localized.string("settings.recipes_section")) {
                ForEach(RecipeRegistry.builtIn(), id: \.id) { recipe in
                    recipeRow(recipe)
                }
            }

            let projectRecipes = ProjectRecipes.make(
                devRoots: config.devRoots,
                homeDirectory: NSHomeDirectory()
            )
            if !projectRecipes.isEmpty {
                Section(Localized.string("settings.project_recipes_section")) {
                    ForEach(projectRecipes, id: \.id) { recipe in
                        recipeRow(recipe, projectBadge: true)
                    }
                }
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

            Section(Localized.string("settings.devroots_section")) {
                if config.devRoots.isEmpty {
                    Text(Localized.string("settings.devroots_empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(config.devRoots, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(Localized.string("common.remove")) {
                                service.removeDevRoot(path)
                                config.devRoots.removeAll { $0 == path }
                            }
                            .cursorPointingHand()
                        }
                    }
                    Text(Localized.string("settings.devroots_recipes_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(Localized.string("settings.candidates_section")) {
                let pending = state.candidateRecipes.filter { $0.status == .pending }
                if pending.isEmpty {
                    Text(Localized.string("insights.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.pattern)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(Localized.string("candidate.evidence", candidate.evidenceCount)
                                     + " · " + Format.bytes(candidate.totalGrowthBytes))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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
                let accepted = state.candidateRecipes.filter { $0.status == .accepted }
                if !accepted.isEmpty {
                    Divider()
                    ForEach(accepted) { candidate in
                        HStack {
                            Text(candidate.pattern)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(Localized.string("common.remove")) {
                                service.dismissCandidate(id: candidate.id)
                            }
                            .cursorPointingHand()
                        }
                    }
                }
            }
        } else {
            Text(Localized.string("settings.recipes_expert_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
    private func recipeRow(_ recipe: Recipe, projectBadge: Bool = false) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedRecipeIDs.contains(recipe.id) },
            set: { expanded in
                if expanded {
                    expandedRecipeIDs.insert(recipe.id)
                } else {
                    expandedRecipeIDs.remove(recipe.id)
                }
            }
        )) {
            ForEach(recipePaths(recipe), id: \.self) { path in
                recipePathRow(path)
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { isEnabled(recipe) },
                    set: { setEnabled(recipe, $0) }
                ))
                .labelsHidden()
                Text(Localized.recipeName(recipe.id, fallback: recipe.name))
                    .lineLimit(1)
                if projectBadge {
                    Text(Localized.string("settings.project_badge"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                }
                Spacer()
                Text(Localized.string("settings.keep_days", age(recipe)))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 74, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { age(recipe) },
                    set: { setAge(recipe, $0) }
                ), in: 1...365)
                .labelsHidden()
            }
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

    /// 配方解析出的具体路径（可能为空：路径不存在时配方不生效）。
    private func recipePaths(_ recipe: Recipe) -> [String] {
        recipe.resolvePaths(StoragePaths(homeDirectory: NSHomeDirectory()))
    }

    /// 路径行：具体路径始终可点击。路径存在时在 Finder 中打开它本身；
    /// 路径当前不存在时打开其上级目录，并给出提示。
    @ViewBuilder
    private func recipePathRow(_ path: String) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            Button {
                FinderReveal.reveal(path)
            } label: {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .cursorPointingHand()
            .help(path)
        } else {
            Button {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                FinderReveal.reveal(parent)
            } label: {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .cursorPointingHand()
            .help(Localized.string("settings.path_missing"))
        }
    }
}
