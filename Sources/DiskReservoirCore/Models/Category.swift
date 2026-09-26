public enum Category: String, Codable, CaseIterable, Sendable {
    case xcode
    case simulator
    case packageManager
    case project
    case common
    case custom
    /// 下载即资产（iOS 设备备份、本地大模型、虚拟盘等）：只监视增长，永不清理。
    case asset
}
