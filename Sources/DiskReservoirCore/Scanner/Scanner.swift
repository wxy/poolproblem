import Foundation

public struct ScanResult: Sendable {
    public let volume: VolumeInfo
    public let items: [ScanItem]
    public let records: [FileRecord]
    public let volumeURL: URL

    public init(volume: VolumeInfo, items: [ScanItem], records: [FileRecord], volumeURL: URL) {
        self.volume = volume
        self.items = items
        self.records = records
        self.volumeURL = volumeURL
    }
}

public struct Scanner: Sendable {
    private let now: @Sendable () -> Date
    private let includeHidden: Bool
    private let cloneRatios: [String: Double]
    /// 每个配方覆盖的年龄阈值（天），来自 Config.rules 的用户设置；
    /// 未配置时回落到 recipe.defaultAgeDays。
    private let ageDaysByRecipe: [String: Int]

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        includeHidden: Bool = true,
        cloneRatios: [String: Double] = [:],
        ageDaysByRecipe: [String: Int] = [:]
    ) {
        self.now = now
        self.includeHidden = includeHidden
        self.cloneRatios = cloneRatios
        self.ageDaysByRecipe = ageDaysByRecipe
    }

    public func scan(recipes: [Recipe], homeDirectory: String) throws -> ScanResult {
        let paths = StoragePaths(baseURL: nil, homeDirectory: homeDirectory)
        var items: [ScanItem] = []
        var records: [FileRecord] = []
        for recipe in recipes {
            let resolved = recipe.resolvePaths(paths)
            if recipe.aggregatesPaths {
                if let item = aggregateItem(recipe: recipe, paths: resolved, homeDirectory: homeDirectory) {
                    items.append(item)
                }
                continue
            }
            for path in resolved {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if recipe.usageProbe == .simulatorRuntimeLastBooted {
                    items.append(contentsOf: runtimeItems(
                        recipe: recipe,
                        parentPath: path,
                        homeDirectory: homeDirectory
                    ))
                    continue
                }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let itemID = "\(recipe.id):\(path)"
                let (size, allocated, count, modified, files) = try measureDirectory(
                    url,
                    itemID: itemID,
                    // 不可清理目录（如废纸篓）只展示大小，不需要逐文件明细；
                    // 用轻量 POSIX 汇总，避免几十万文件的目录把扫描拖到分钟级
                    lightWeight: recipe.disposition == .none
                )
                items.append(ScanItem(
                    id: itemID,
                    recipeID: recipe.id,
                    name: recipe.name,
                    path: path,
                    category: recipe.category,
                    safety: recipe.safety,
                    disposition: recipe.disposition,
                    sizeBytes: size,
                    allocatedBytes: allocated,
                    reclaimableBytes: allocated,
                    fileCount: count,
                    lastModified: effectiveLastModified(modified, recipe: recipe, path: path)
                ))
                records.append(contentsOf: files)
            }
        }
        let volume = VolumeReader.read(fileURL: URL(fileURLWithPath: homeDirectory))
        var honestItems = ReclaimableEstimator().apply(to: items, records: records)
        // 克隆型配方（如 XCTestDevices）按校准比例估算真实可释放量
        honestItems = honestItems.map { item in
            guard let recipe = recipes.first(where: { $0.id == item.recipeID }), recipe.cloneProne else {
                return item
            }
            let ratio = cloneRatios[item.recipeID] ?? 0.2
            return ScanItem(
                id: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                paths: item.paths,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: item.sizeBytes,
                allocatedBytes: item.allocatedBytes,
                reclaimableBytes: Int64(Double(item.allocatedBytes) * ratio),
                fileCount: item.fileCount,
                lastModified: item.lastModified
            )
        }
        return ScanResult(
            volume: volume,
            items: honestItems,
            records: records,
            volumeURL: URL(fileURLWithPath: homeDirectory)
        )
    }

    /// 重扫单个配方路径（增量用）：普通配方返回 1 项，运行时配方返回展开的子项。
    public func rescan(
        path: String,
        recipe: Recipe,
        homeDirectory: String
    ) -> [ScanItem] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        if recipe.aggregatesPaths {
            let resolved = recipe.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: homeDirectory))
            return aggregateItem(recipe: recipe, paths: resolved, homeDirectory: homeDirectory).map { [$0] } ?? []
        }
        if recipe.usageProbe == .simulatorRuntimeLastBooted {
            return runtimeItems(recipe: recipe, parentPath: path, homeDirectory: homeDirectory)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let itemID = "\(recipe.id):\(path)"
        guard let (size, allocated, count, modified, _) = try? measureDirectory(
            url,
            itemID: itemID,
            lightWeight: recipe.disposition == .none
        ) else { return [] }
        var item = ScanItem(
            id: itemID,
            recipeID: recipe.id,
            name: recipe.name,
            path: path,
            category: recipe.category,
            safety: recipe.safety,
            disposition: recipe.disposition,
            sizeBytes: size,
            allocatedBytes: allocated,
            reclaimableBytes: allocated,
            fileCount: count,
            lastModified: effectiveLastModified(modified, recipe: recipe, path: path),
            cleanability: recipe.cleanability
        )
        if recipe.cloneProne {
            item = ScanItem(
                id: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: item.sizeBytes,
                allocatedBytes: item.allocatedBytes,
                reclaimableBytes: Int64(Double(item.allocatedBytes) * (self.cloneRatios[recipe.id] ?? 0.2)),
                fileCount: item.fileCount,
                lastModified: item.lastModified,
                cleanability: item.cleanability
            )
        }
        return [item]
    }

    /// 聚合路径配方：把 resolvePaths 的多个路径合并为一个条目
    /// （项目目录聚类：一个"项目 node_modules"条目汇总所有项目）。
    private func aggregateItem(recipe: Recipe, paths: [String], homeDirectory: String) -> ScanItem? {
        var size: Int64 = 0
        var allocated: Int64 = 0
        var count = 0
        var newest: Date?
        var existing: [String] = []
        let ageLimitDays = ageDaysByRecipe[recipe.id] ?? recipe.defaultAgeDays
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let itemID = "\(recipe.id):\(path)"
            guard let (s, a, c, m, _) = try? measureDirectory(
                url,
                itemID: itemID,
                lightWeight: recipe.disposition == .none
            ) else { continue }
            // 只聚合“足够老”的子路径：未达到年龄阈值或最近 24h 有修改的
            // 项目不进入可清理清单（也不参与清理）。
            let effective = effectiveLastModified(m, recipe: recipe, path: path)
            guard CleanabilityRules.isOldEnough(
                lastModified: effective,
                ageLimitDays: ageLimitDays,
                minimumIdleHours: recipe.minimumIdleHours,
                now: now()
            ) else { continue }
            existing.append(path)
            size += s
            allocated += a
            count += c
            if let effective, effective > (newest ?? .distantPast) {
                newest = effective
            }
        }
        guard !existing.isEmpty else { return nil }
        var reclaimable = allocated
        if recipe.cloneProne {
            reclaimable = Int64(Double(allocated) * (cloneRatios[recipe.id] ?? 0.2))
        }
        return ScanItem(
            id: "\(recipe.id):aggregate",
            recipeID: recipe.id,
            name: recipe.name,
            path: paths.first ?? "",
            paths: existing,
            category: recipe.category,
            // 聚合条目里的路径都已通过年龄门槛，视为可直接清理，不再要求用户逐次确认
            safety: .safeWhileRunning,
            disposition: recipe.disposition,
            sizeBytes: size,
            allocatedBytes: allocated,
            reclaimableBytes: reclaimable,
            fileCount: count,
            lastModified: newest,
            cleanability: recipe.cleanability
        )
    }

    /// parentAndSelfNewestModified 探针：最后使用时间取 自身 与 上级目录 最新 mtime 的较新者。
    private func effectiveLastModified(_ modified: Date?, recipe: Recipe, path: String) -> Date? {
        guard recipe.usageProbe == .parentAndSelfNewestModified else { return modified }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let walk = POSIXDirectoryWalker.walk(
            url: parent,
            itemID: parent.path,
            includeRecords: false
        ) else { return modified }
        switch (modified, walk.newest) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// 运行时镜像/缓存配方：把父路径的一级子目录展开为独立条目，
    /// 并用 `lastBootedAt` 作为“最后使用时间”。
    private func runtimeItems(
        recipe: Recipe,
        parentPath: String,
        homeDirectory: String
    ) -> [ScanItem] {
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let devicesRoot = homeDirectory + "/Library/Developer/CoreSimulator/Devices"
        var items: [ScanItem] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard let runtimeID = SimulatorRuntimeUsage.runtimeIdentifier(forPath: child.path) else {
                continue
            }
            let itemID = "\(recipe.id):\(child.path)"
            guard let (size, allocated, count, _, _) = try? measureDirectory(
                child,
                itemID: itemID,
                lightWeight: true
            ) else { continue }
            let lastUsed = SimulatorRuntimeUsage.lastBootedDate(
                devicesRoot: devicesRoot,
                runtimeID: runtimeID
            )
            items.append(ScanItem(
                id: itemID,
                recipeID: recipe.id,
                name: recipe.name,
                path: child.path,
                category: recipe.category,
                safety: recipe.safety,
                disposition: recipe.disposition,
                sizeBytes: size,
                allocatedBytes: allocated,
                reclaimableBytes: allocated,
                fileCount: count,
                lastModified: lastUsed,
                cleanability: recipe.cleanability
            ))
        }
        return items
    }

    private func measureDirectory(
        _ url: URL,
        itemID: String,
        lightWeight: Bool = false
    ) throws -> (size: Int64, allocated: Int64, count: Int, modified: Date?, files: [FileRecord]) {
        if lightWeight {
            if let posix = POSIXDirectoryWalker.walk(url: url, itemID: itemID, includeRecords: false) {
                return (posix.sizeBytes, posix.allocatedBytes, posix.fileCount, posix.newest, [])
            }
            // POSIX 打不开（如缺少权限）时回落到 FileManager 路径，结果为空也是安全值
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        var size: Int64 = 0
        var allocated: Int64 = 0
        var count = 0
        var newest: Date?
        var files: [FileRecord] = []
        while let element = enumerator?.nextObject() as? URL {
            let values = try element.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                let alloc = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                size += Int64(values.fileSize ?? 0)
                allocated += alloc
                count += 1
                let fileStat = element.withUnsafeFileSystemRepresentation { ptr -> stat in
                    var st = stat()
                    if let ptr { stat(ptr, &st) }
                    return st
                }
                files.append(FileRecord(
                    itemID: itemID,
                    url: element,
                    allocatedBytes: alloc,
                    deviceID: fileStat.st_dev,
                    inode: fileStat.st_ino,
                    lastModified: values.contentModificationDate ?? .distantPast
                ))
                if let date = values.contentModificationDate, date > (newest ?? .distantPast) {
                    newest = date
                }
            }
        }
        // FileManager 对 ~/.Trash 等受保护目录存在已知问题：即使拥有完全磁盘访问，
        // 枚举也会静默返回空列表。此时改用 POSIX 枚举兜底（同样受 TCC 约束，
        // 无权限时 opendir 会失败并保持原结果）。
        if count == 0, let posix = POSIXDirectoryWalker.walk(url: url, itemID: itemID) {
            return (posix.sizeBytes, posix.allocatedBytes, posix.fileCount, posix.newest, posix.files)
        }
        return (size, allocated, count, newest, files)
    }
}
