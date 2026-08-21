import AppKit

/// 在 Finder 中显示指定路径的统一入口。
///
/// 路径不存在时直接忽略，避免对无效/特殊路径（如只读挂载卷、TCC 保护的
/// `~/.Trash`）触发系统 FileID 解析并产生 `FileIDTreeGetVRefNumForDevice`
/// 之类的 I/O 噪音。
enum FinderReveal {
    static func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
