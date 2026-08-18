import Foundation

/// 清理底线：被程序清理的文件必须不会造成不可挽回的结果。
///
/// - `regenerable`: 可再生 / 可再下载，程序可以按规则自动清理（trash 或永久删除均可）。
/// - `trashOnly`: 不可再生，只能进回收站且需要用户确认；禁止永久删除。
/// - `displayOnly`: 用户数据，程序永不清理，只展示大小。
public enum Cleanability: String, Codable, CaseIterable, Sendable {
    case regenerable
    case trashOnly
    case displayOnly
}
