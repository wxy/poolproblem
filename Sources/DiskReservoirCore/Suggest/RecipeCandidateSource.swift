import Foundation

/// 配方建议候选的来源：说明“为什么会被建议”。
public enum RecipeCandidateSource: String, Codable, Sendable {
    /// 增长台账：该目录最近增长明显，且符合现有配方类型但未被监控。
    case growth
    /// 主动发现：该目录包含大量可再生产物（node_modules / dist / build）。
    case discovery
    /// 近期写活动：FSEvents 观察到该目录近期有可再生产物写入（可能是新项目）。
    case activity
}
