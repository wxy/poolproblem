import Foundation

/// CLI 本地化辅助：按当前语言在中文与英文间切换。
/// 仅作用于人类可读输出与帮助文案；JSON 输出保持英文 key 不变（机器接口）。
enum CLILocalized {
    /// 测试可用 `POOLPROBLEM_LANG=zh|en` 覆盖系统语言
    static var isChinese: Bool {
        if let env = ProcessInfo.processInfo.environment["POOLPROBLEM_LANG"] {
            return env.lowercased().hasPrefix("zh")
        }
        let lang = Locale.current.language.languageCode?.identifier.lowercased()
        return lang == "zh" || lang?.hasPrefix("zh") == true
    }

    static func string(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return isChinese ? entry.zh : entry.en
    }

    static func string(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    private struct Entry {
        let en: String
        let zh: String
    }

    private static let table: [String: Entry] = [
        "cli.abstract": Entry(
            en: "The Pool Problem - disk reservoir: scan, predict, clean.",
            zh: "The Pool Problem - 磁盘蓄水池：扫描、预测、清理。"
        ),
        "flag.json": Entry(en: "Output JSON", zh: "输出 JSON"),
        "flag.dry_run": Entry(en: "Preview only, do not actually delete", zh: "只预览，不实际删除"),

        "scan.abstract": Entry(
            en: "Scan recipes and report sizes and reclaimable space",
            zh: "扫描各配方并输出大小与可释放量"
        ),
        "scan.available": Entry(en: "Available: %lld bytes", zh: "可用: %lld 字节"),
        "scan.item": Entry(en: "%@: reclaimable %lld bytes (%@)", zh: "%@: 可释放 %lld 字节 (%@)"),

        "suggest.abstract": Entry(
            en: "Suggest cleanable items per rules",
            zh: "按规则给出可清理建议"
        ),

        "clean.abstract": Entry(
            en: "Clean according to the waterline and rules",
            zh: "按水线与规则执行清理"
        ),
        "clean.summary": Entry(
            en: "Items: %d, estimated freed: %lld, actual freed: %lld",
            zh: "清理项: %d，估算释放: %lld，实测释放: %lld"
        ),

        "status.abstract": Entry(
            en: "Water level, prediction and recent clean history",
            zh: "水位、预测与最近清理记录"
        ),
        "status.available": Entry(en: "Available: %lld bytes (%ld snapshots)", zh: "可用: %lld 字节（快照 %ld 份）"),
        "status.no_snapshot": Entry(
            en: "No snapshots yet. Run 'scan' first (the App saves automatically).",
            zh: "尚无快照，请先运行 scan 并保存（后续 App 版会自动保存）。"
        ),
        "status.prediction": Entry(
            en: "At the current rate, the waterline will be reached in about %d days.",
            zh: "按当前流速，约 %d 天后到水线。"
        ),
        "status.clean_log": Entry(en: "Clean %@: %lld bytes (%@)", zh: "清理 %@：%lld 字节 (%@)"),
    ]
}
