import Foundation

/// 模拟器运行时镜像与 dyld 缓存的“最后使用时间”探针。
///
/// 运行时镜像和 dyld 缓存是静态下载物，目录 mtime 只反映安装/构建时间。
/// 权威信号是 `~/Library/Developer/CoreSimulator/Devices/*/device.plist`
/// 里的 `lastBootedAt`（最后启动时间），按 runtime 标识映射。
enum SimulatorRuntimeUsage {
    /// 解析运行时路径对应的 runtime 标识（如 `com.apple.CoreSimulator.SimRuntime.iOS-26-5`）。
    static func runtimeIdentifier(forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)

        // 运行时镜像：读取 .simruntime 包内的 Info.plist
        let runtimes = url.appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimes,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.pathExtension == "simruntime" {
                let info = entry.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: info),
                   let plist = try? PropertyListSerialization.propertyList(
                       from: data,
                       options: [],
                       format: nil
                   ) as? [String: Any],
                   let id = plist["CFBundleIdentifier"] as? String {
                    return id
                }
            }
        }

        // dyld 缓存目录名形如 com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77，
        // 去掉末尾的构建号即为 runtime 标识。
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.CoreSimulator.SimRuntime."),
           let dot = name.lastIndex(of: ".") {
            let build = name[name.index(after: dot)...]
            if !build.isEmpty, build.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return String(name[..<dot])
            }
        }
        return nil
    }

    /// 给定 runtime 标识，返回所有设备 `lastBootedAt` 的最大值；没有设备则为 nil。
    static func lastBootedDate(devicesRoot: String, runtimeID: String) -> Date? {
        let devices = URL(fileURLWithPath: devicesRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: devices,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        var newest: Date?
        for device in entries {
            let plistURL = device.appendingPathComponent("device.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: Any],
                  (plist["runtime"] as? String) == runtimeID,
                  let date = plist["lastBootedAt"] as? Date else { continue }
            if date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }
}
