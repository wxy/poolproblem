import Foundation

/// 清理底线：被程序清理的文件必须不会造成不可挽回的结果。
///
/// - `regenerable`: 可再生 / 可再下载，程序可以按规则自动清理（trash 或永久删除均可）。
/// - `trashOnly`: 不可再生，只能进回收站且需要用户确认；禁止永久删除。
/// - `displayOnly`: 用户数据，程序永不清理，只展示大小。
/// - `watchOnly`: 监视清单（下载即资产：设备备份、模型权重、虚拟盘等）。
///   参与扫描、归因与满盘预测；清理引擎与建议器硬排除，永不清理、永不产生建议。
///   层级语义见 docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §1。
public enum Cleanability: String, Codable, CaseIterable, Sendable {
    case regenerable
    case trashOnly
    case displayOnly
    case watchOnly
}
