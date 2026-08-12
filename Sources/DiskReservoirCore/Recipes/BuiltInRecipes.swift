import Foundation

enum BuiltInRecipes {
    static let all: [Recipe] = [
        Recipe(
            id: "xctestdevices",
            name: "XCTestDevices 测试快照",
            category: .xcode,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
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
            disposition: .deletePermanently,
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
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Caches/Homebrew"]
            }
        ),
        Recipe(
            id: "library-caches",
            name: "应用缓存 (~/Library/Caches)",
            category: .common,
            safety: .safeWhileRunning,
            disposition: .trash,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            resolvePaths: { paths in
                [paths.homeDirectory + "/Library/Caches"]
            }
        ),
        Recipe(
            id: "trash",
            name: "废纸篓",
            category: .common,
            safety: .userConfirm,
            disposition: .none,
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
