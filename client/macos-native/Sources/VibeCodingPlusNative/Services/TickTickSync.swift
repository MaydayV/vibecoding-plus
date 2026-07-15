import Foundation

actor TickTickSync {
    private let apiClient = TickTickAPIClient()
    private var config: ServerConfig
    private var timer: Timer?
    private var lastSyncAt: Date?
    private var lastError: String?
    private var syncCount: Int = 0

    init(config: ServerConfig) {
        self.config = config
    }

    func updateConfig(_ config: ServerConfig) {
        self.config = config
    }

    func sync(todoService: TodoService) async {
        guard config.tickTickSyncEnabled, !config.tickTickAccessToken.isEmpty else {
            lastError = nil
            return
        }

        await apiClient.updateToken(config.tickTickAccessToken)
        let projectId = config.tickTickProjectId

        do {
            try await pushLocalChanges(todoService: todoService, projectId: projectId)
            try await pullRemoteChanges(todoService: todoService, projectId: projectId)
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = "TickTick sync failed: \(error.localizedDescription)"
        }
    }

    func fetchProjects() async throws -> [TickTickProjectInfo] {
        guard !config.tickTickAccessToken.isEmpty else { throw TickTickError.missingToken }
        await apiClient.updateToken(config.tickTickAccessToken)
        let projects = try await apiClient.fetchProjects()
        return projects.map { TickTickProjectInfo(id: $0.id, title: $0.name, taskCount: 0) }
    }

    func deleteTask(taskId: String) async throws {
        guard !config.tickTickAccessToken.isEmpty else { throw TickTickError.missingToken }
        await apiClient.updateToken(config.tickTickAccessToken)
        try await apiClient.deleteTask(taskId: taskId)
    }

    func startPeriodicSync(todoService: TodoService) {
        stopPeriodicSync()
        let interval = max(15, config.tickTickPollSec)
        let newTimer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.sync(todoService: todoService)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stopPeriodicSync() {
        timer?.invalidate()
        timer = nil
    }

    func status() -> TickTickSyncStatus {
        TickTickSyncStatus(
            enabled: config.tickTickSyncEnabled,
            lastSyncAt: lastSyncAt?.timeIntervalSince1970,
            syncCount: syncCount,
            lastError: lastError,
            projectId: config.tickTickProjectId,
            pollSec: config.tickTickPollSec
        )
    }

    // MARK: - Private

    private func pushLocalChanges(todoService: TodoService, projectId: String) async throws {
        guard !projectId.isEmpty else { return }
        let dirtyItems = await todoService.getDirtySyncItems(for: .ticktick)

        for item in dirtyItems {
            let task = TickTickTask(
                id: item.ticktickId,
                projectId: projectId,
                title: item.title,
                content: nil,
                desc: nil,
                status: item.completed ? 2 : 0,
                priority: 0,
                isAllDay: true,
                startDate: nil,
                dueDate: item.dueAt,
                timeZone: TimeZone.current.identifier,
                completedTime: nil
            )

            if let remoteId = item.ticktickId, !remoteId.isEmpty {
                _ = try await apiClient.updateTask(task)
                await todoService.markItemSynced(id: item.id, service: .ticktick, remoteId: remoteId, projectId: projectId)
            } else {
                let created = try await apiClient.createTask(task)
                if let newId = created.id {
                    await todoService.markItemSynced(id: item.id, service: .ticktick, remoteId: newId, projectId: projectId)
                }
            }
            syncCount += 1
        }
    }

    private func pullRemoteChanges(todoService: TodoService, projectId: String) async throws {
        guard !projectId.isEmpty else { return }
        let remoteTasks = try await apiClient.fetchTasks(projectId: projectId)

        for task in remoteTasks {
            guard let remoteId = task.id, !remoteId.isEmpty else { continue }
            let completed = task.status == 2
            await todoService.applyRemoteTickTickTask(
                ticktickId: remoteId,
                projectId: task.projectId,
                title: task.title,
                dueDate: task.dueDate,
                completed: completed
            )
        }

        let validIds = Set(remoteTasks.compactMap { $0.id })
        await todoService.pruneRemoteMissingTickTickIds(validIds: validIds)
        syncCount += remoteTasks.count
    }
}
