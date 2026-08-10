import SwiftUI
import DiskReservoirCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    let service: AppService

    @State private var config: Config = .default
    @State private var expertMode = false
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var newWhitelistPath = ""
    @State private var hasFullDiskAccess = false

    var body: some View {
        Form {
            Section("水位") {
                HStack {
                    Text("目标可用空间")
                    Slider(value: waterlineBinding, in: 10...100, step: 5)
                    Text("\(Int(config.waterlineGB)) GB")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("运行模式") {
                Picker("模式", selection: $expertMode) {
                    Text("傻瓜模式（全自动）").tag(false)
                    Text("专家模式（精细控制）").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if expertMode {
                Section("清理配方") {
                    ForEach(RecipeRegistry.builtIn(), id: \.id) { recipe in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { isEnabled(recipe) },
                                set: { setEnabled(recipe, $0) }
                            ))
                            .labelsHidden()
                            Text(recipe.name)
                                .lineLimit(1)
                            Spacer()
                            Stepper("保留 \(age(recipe)) 天", value: Binding(
                                get: { age(recipe) },
                                set: { setAge(recipe, $0) }
                            ), in: 1...365)
                        }
                    }
                }

                Section("白名单（永不清理）") {
                    ForEach(config.whitelistPaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).lineLimit(1)
                            Spacer()
                            Button("移除") {
                                config.whitelistPaths.removeAll { $0 == path }
                            }
                        }
                    }
                    HStack {
                        TextField("输入路径…", text: $newWhitelistPath)
                            .textFieldStyle(.roundedBorder)
                        Button("添加") {
                            let trimmed = newWhitelistPath.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty, !config.whitelistPaths.contains(trimmed) {
                                config.whitelistPaths.append(trimmed)
                            }
                            newWhitelistPath = ""
                        }
                        .disabled(newWhitelistPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section("权限") {
                HStack {
                    Image(systemName: hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                    Text(hasFullDiskAccess
                         ? "完全磁盘访问已授权"
                         : "需要完全磁盘访问才能扫描受保护目录（如 ~/Library/Containers）")
                    Spacer()
                    if !hasFullDiskAccess {
                        Button("去设置") { PermissionService.openSystemSettings() }
                        Button("重新检测") {
                            Task {
                                PermissionService.resetCache()
                                hasFullDiskAccess = await PermissionService.hasFullDiskAccess()
                            }
                        }
                    }
                }
            }

            Section("通用") {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        try? LaunchAtLoginService.setEnabled(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: expertMode ? 620 : 320)
        .onAppear {
            config = service.loadConfig()
            expertMode = UserDefaults.standard.bool(forKey: "expertMode")
        }
        .task {
            hasFullDiskAccess = await PermissionService.hasFullDiskAccess()
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
