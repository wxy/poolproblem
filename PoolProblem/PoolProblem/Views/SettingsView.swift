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

    var body: some View {
        Form {
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

            if expertMode {
                Section(Localized.string("settings.recipes_section")) {
                    ForEach(RecipeRegistry.builtIn(), id: \.id) { recipe in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { isEnabled(recipe) },
                                set: { setEnabled(recipe, $0) }
                            ))
                            .labelsHidden()
                            Text(Localized.recipeName(recipe.id, fallback: recipe.name))
                                .lineLimit(1)
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
            }

            Section(Localized.string("settings.protected_children_section")) {
                ForEach(config.protectedCacheChildren, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption).lineLimit(1)
                        Spacer()
                        Button(Localized.string("common.remove")) {
                            config.protectedCacheChildren.removeAll { $0 == name }
                        }
                        .cursorPointingHand()
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

            Section(Localized.string("settings.general_section")) {
                Toggle(Localized.string("settings.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        try? LaunchAtLoginService.setEnabled(newValue)
                    }
            }
        }
        .formStyle(.grouped)
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
}
