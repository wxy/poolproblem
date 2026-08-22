import Foundation

/// 清理协调器：把所有清理/清空/恢复任务串行化。
///
/// 自动水线清理、渐进清理、手动“立即清理”、详情页一键清理、废纸篓清空/恢复
/// 全部通过 `run` 排队执行，同一时刻只运行一个任务，避免并发删除同一目录、
/// 日志追加竞争与状态标志互相覆盖。
///
/// 注意：任务内部不要再调用 `run`（会造成任务链自等死锁）。
@MainActor
final class CleanupCoordinator {
    private var chain: Task<Void, Never> = Task {}
    private var activeJobs = 0
    private let onCleaningChange: @MainActor (Bool) -> Void

    init(onCleaningChange: @escaping @MainActor (Bool) -> Void) {
        self.onCleaningChange = onCleaningChange
    }

    /// 当前是否有清理任务在运行或排队。
    var isCleaning: Bool { activeJobs > 0 }

    /// 排队执行一个清理任务；调用方会等待自己的任务完成。
    func run<T: Sendable>(_ job: @escaping @MainActor () async -> T) async -> T {
        if activeJobs == 0 {
            onCleaningChange(true)
        }
        activeJobs += 1
        defer {
            activeJobs -= 1
            if activeJobs == 0 {
                onCleaningChange(false)
            }
        }
        let previous = chain
        let task = Task { @MainActor in
            await previous.value
            return await job()
        }
        chain = Task { await task.value }
        return await task.value
    }
}
