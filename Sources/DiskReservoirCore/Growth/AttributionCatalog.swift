import Foundation

/// 归因识别表：把表面扫描条目的裸路径翻译成可读的「这是什么」。
///
/// 设计约束（docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §1.1）：
/// - **零扫描成本**：只对表面扫描已产出的条目做字符串匹配，绝不自己遍历文件系统；
/// - **层级语义**：`asset` = 建议纳入监视（下载即资产）、`cleanCandidate` = 可建议纳入
///   清理配方族（活跃开发期增长显著）、`info` = 已知但不关注（增长缓慢或幅度小，
///   见方案「不关注清单」，避免重复讨论）；
/// - 条目准入复用产品契约：必须有实测证据（来源 docs/research/2026-09-24-mole-lessons.md），
///   路径事实来自 Mole 的公开经验与 Apple 文档，不含任何 GPL 代码。
public enum AttributionCatalog: Sendable {

    public enum Layer: String, Codable, Sendable {
        /// 下载即资产：建议纳入监视清单（watchOnly）。
        case asset
        /// 可建议纳入清理配方族（经增长门槛与用户采纳后）。
        case cleanCandidate
        /// 已知但不关注：仅命名归因，永不建议。
        case info
    }

    public enum Match: String, Sendable {
        /// 路径以模式结尾（区分度高，用于已知完整位置）。
        case suffix
        /// 任一路径组件以模式结尾（用于通配归属，如 `*.dev.orbstack`）。
        case component
    }

    public struct Entry: Sendable {
        public let pattern: String
        public let match: Match
        /// 展示名（与配方名一致使用中文 + ASCII 标识）。
        public let name: String
        public let layer: Layer
        /// 具名下钻：命中后向下查看的这一层缓存子目录（nil = 不下钻）。
        public let cacheSubdirectory: String?

        init(
            _ pattern: String,
            match: Match = .suffix,
            name: String,
            layer: Layer,
            drillInto cacheSubdirectory: String? = nil
        ) {
            self.pattern = pattern
            self.match = match
            self.name = name
            self.layer = layer
            self.cacheSubdirectory = cacheSubdirectory
        }
    }

    /// 识别表。匹配按 pattern 长度降序进行：更深的模式优先，保证
    /// 「Slack/Cache」命中缓存条目而不是外层「Slack」条目。
    public static let all: [Entry] = [
        // MARK: 资产（.asset）：只监视，永不清理
        Entry("Library/Application Support/MobileSync/Backup", name: "iOS 设备备份", layer: .asset),
        Entry("Library/Containers/com.docker.docker", name: "Docker Desktop 数据", layer: .asset),
        Entry("dev.orbstack", match: .component, name: "OrbStack 数据", layer: .asset),
        Entry(".lima", match: .component, name: "Lima 虚拟机", layer: .asset),
        Entry(".colima", match: .component, name: "Colima 虚拟机", layer: .asset),
        Entry(".ollama/models", name: "Ollama 本地模型", layer: .asset),
        Entry(".lmstudio/models", name: "LM Studio 本地模型", layer: .asset),

        // MARK: 清理候选（.cleanCandidate）：增长显著，可经建议管道纳入配方族
        Entry(".cache/go-build", name: "Go 构建缓存", layer: .cleanCandidate),
        Entry("go/pkg/mod", name: "Go 模块缓存", layer: .cleanCandidate),
        Entry(".gradle/caches", name: "Gradle 缓存", layer: .cleanCandidate),
        Entry(".cargo/registry/cache", name: "Cargo registry 缓存", layer: .cleanCandidate),
        Entry(".yarn/berry/cache", name: "Yarn 缓存", layer: .cleanCandidate),
        Entry(".bun/install/cache", name: "Bun 缓存", layer: .cleanCandidate),

        // MARK: 已知不关注（.info）：仅命名，永不建议
        Entry("Library/Application Support/com.tencent.xinWeChat", name: "微信数据", layer: .info),
        Entry("Library/Application Support/com.tencent.WeWorkMac", name: "企业微信数据", layer: .info),
        Entry("Library/Application Support/Slack/Cache", name: "Slack 缓存", layer: .info),
        Entry("Library/Application Support/Slack", name: "Slack 数据", layer: .info, drillInto: "Cache"),
        Entry("Library/Application Support/iDingTalk/log", name: "钉钉日志", layer: .info),
        Entry("Library/Application Support/iDingTalk", name: "钉钉（iDingTalk）数据", layer: .info, drillInto: "log"),
        Entry("Library/Caches/ms-playwright", name: "Playwright 浏览器", layer: .info),
        Entry("Library/Developer/Xcode/UserData/IB Support", name: "Xcode Interface Builder 缓存", layer: .info),
        Entry("anaconda3/pkgs", name: "Conda 包缓存", layer: .info),
        Entry("miniconda3/pkgs", name: "Conda 包缓存", layer: .info),
        Entry("miniforge3/pkgs", name: "Conda 包缓存", layer: .info),
        Entry("mambaforge/pkgs", name: "Conda 包缓存", layer: .info),
        Entry(".conda/pkgs", name: "Conda 包缓存", layer: .info),
        Entry(".m2/repository", name: "Maven 本地仓库", layer: .info),
        Entry(".nuget/packages", name: "NuGet 本地仓库", layer: .info),
        Entry("var/db/diagnostics", name: "系统统一日志", layer: .info),
        Entry("Code Cache", name: "Electron Code Cache", layer: .info),
        Entry("GPUCache", name: "Electron GPU 缓存", layer: .info),
        Entry("DawnWebGPUCache", name: "Electron WebGPU 缓存", layer: .info),
        Entry("DawnCache", name: "Electron Dawn 缓存", layer: .info),
        Entry("GraphiteCache", name: "Electron Graphite 缓存", layer: .info),
    ]

    /// 预排序的匹配表：pattern 长度降序，保证更具体（更深）的模式优先命中。
    private static let sorted: [Entry] = all.sorted { $0.pattern.count > $1.pattern.count }

    /// 路径 → 识别条目。未知路径返回 nil（调用方回落到路径末段展示）。
    public static func attribution(forPath path: String) -> Entry? {
        let standardized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let components = standardized.split(separator: "/").map(String.init)
        return sorted.first { entry in
            switch entry.match {
            case .suffix:
                return standardized.hasSuffix(entry.pattern)
            case .component:
                return components.contains { $0.hasSuffix(entry.pattern) }
            }
        }
    }

    /// 路径 → 展示名；未知路径返回 nil。
    public static func displayName(forPath path: String) -> String? {
        attribution(forPath: path)?.name
    }

    /// 具名下钻：对命中识别表且声明了 `cacheSubdirectory` 的表面条目，
    /// 向下多看一层缓存子目录并作为独立表面条目返回。
    /// 只对匹配项展开（成本有界），不满足大小下限的子目录被丢弃。
    public static func drillDown(
        directories: [SurfaceDirectory],
        minimumSizeBytes: Int64 = 50 << 20,
        scanner: SurfaceScanner = SurfaceScanner()
    ) -> [SurfaceDirectory] {
        var result: [SurfaceDirectory] = []
        for directory in directories {
            guard let entry = attribution(forPath: directory.path),
                  let subdirectory = entry.cacheSubdirectory
            else { continue }
            let subPath = directory.path + "/" + subdirectory
            result.append(contentsOf: scanner.measure(
                paths: [subPath],
                minimumSizeBytes: minimumSizeBytes
            ))
        }
        return result
    }
}
