import Foundation

enum BuiltInRecipes {
    static let all: [Recipe] = [
        Recipe(
            id: "xctestdevices",
            name: "XCTestDevices 测试快照",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 3,
            minimumSizeMB: 100,
            processName: nil,
            cloneProne: true,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/XCTestDevices"]
            }
        ),
        Recipe(
            id: "deriveddata",
            name: "Xcode DerivedData",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 7,
            minimumSizeMB: 100,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/Xcode/DerivedData"]
            }
        ),
        Recipe(
            id: "xcode-archives",
            name: "Xcode Archives",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/Xcode/Archives"]
            }
        ),
        Recipe(
            id: "xcode-docscache",
            name: "Xcode DocumentationCache",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/Xcode/DocumentationCache"]
            }
        ),
        Recipe(
            id: "core-simulator-devices",
            name: "模拟器设备数据",
            category: .simulator,
            safety: .requiresQuit,
            disposition: .trash,
            cleanability: .trashOnly,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: "Simulator",
            cloneProne: true,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/CoreSimulator/Devices"]
            }
        ),
        Recipe(
            id: "npm-cache",
            name: "npm 缓存",
            category: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/.npm"]
            }
        ),
        Recipe(
            id: "pnpm-store",
            name: "pnpm store",
            category: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/pnpm"]
            }
        ),
        Recipe(
            id: "uv-cache",
            name: "uv 缓存",
            category: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/.cache/uv"]
            }
        ),
        Recipe(
            id: "cocoapods-cache",
            name: "CocoaPods 缓存",
            category: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Caches/CocoaPods"]
            }
        ),
        Recipe(
            id: "homebrew-cache",
            name: "Homebrew 缓存",
            category: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Caches/Homebrew"]
            }
        ),
        Recipe(
            id: "library-caches",
            name: "应用缓存",
            category: .common,
            safety: .safeWhileRunning,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            protectedChildren: ["org.swift.swiftpm", "node-gyp"],
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Caches"]
            }
        ),
        Recipe(
            id: "xcode-preview-cache",
            name: "Xcode 预览缓存",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Developer/Xcode/UserData/Previews"]
            }
        ),
        Recipe(
            id: "xcode-devicesupport",
            name: "真机调试支持（旧版本）",
            category: .xcode,
            safety: .userConfirm,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            resolvePaths: { paths in
                // 只返回“除最新版本外”的旧版本目录；当前调试用的版本永远保留。
                // 判定“最新”用目录修改时间：真机连接时 Xcode 会同步/下载对应版本，
                // mtime 即最近一次同步时间。
                let roots = [
                    paths.homeDirectory + "/Library/Developer/Xcode/iOS DeviceSupport",
                    paths.homeDirectory + "/Library/Developer/Xcode/watchOS DeviceSupport",
                ]
                var result: [String] = []
                for root in roots {
                    let url = URL(fileURLWithPath: root, isDirectory: true)
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
                    ) else { continue }
                    let directories = children.filter {
                        ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
                    }
                    guard let newest = directories.max(by: { lhs, rhs in
                        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        return l < r
                    }) else { continue }
                    result += directories.filter { $0.path != newest.path }.map(\.path)
                }
                return result
            }
        ),
        Recipe(
            id: "simulator-runtimes",
            name: "模拟器运行时镜像",
            category: .simulator,
            safety: .userConfirm,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 1000,
            processName: nil,
            usageProbe: .simulatorRuntimeLastBooted,
            resolvePaths: { _ in
                // 扫描时按一级子目录展开成每个运行时一个条目；
                // 删除需要管理员权限，配方只负责展示大小与最后使用时间。
                ["/Library/Developer/CoreSimulator/Volumes"]
            }
        ),
        Recipe(
            id: "simulator-dyld-cache",
            name: "模拟器共享缓存",
            category: .simulator,
            safety: .userConfirm,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            usageProbe: .simulatorRuntimeLastBooted,
            resolvePaths: { _ in
                // dyld 缓存按“代”分目录：dyld/<generation>/<runtime>.<build>，
                // 这里返回各代目录，扫描时再展开成每个运行时一条。
                let dyldRoot = "/Library/Developer/CoreSimulator/Caches/dyld"
                let rootURL = URL(fileURLWithPath: dyldRoot, isDirectory: true)
                guard let generations = try? FileManager.default.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return [] }
                return generations
                    .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true }
                    .map(\.path)
            }
        ),
        Recipe(
            id: "trash",
            name: "废纸篓",
            category: .common,
            safety: .userConfirm,
            disposition: .none,
            cleanability: .displayOnly,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                // 本机废纸篓 + iCloud Drive 废纸篓（启用"桌面与文稿"同步时，
                // 桌面上删除的文件会进 ~/Library/Mobile Documents/.Trash，
                // Finder 的废纸篓会把两者合并展示）
                [
                    paths.homeDirectory + "/.Trash",
                    paths.homeDirectory + "/Library/Mobile Documents/.Trash",
                ]
            }
        ),
    ]
}
