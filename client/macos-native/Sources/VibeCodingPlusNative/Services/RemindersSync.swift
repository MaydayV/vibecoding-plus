import EventKit
import Foundation

// MARK: - Reminders Sync Status

struct RemindersSyncStatus: Sendable {
    var enabled: Bool
    var authorized: Bool
    var listName: String
    var pollSec: Int
    var busy: Bool
    var lastSyncAt: Double
    var lastError: String
    var syncCount: Int
}

// MARK: - Reminders Sync

actor RemindersSync {

    private let store = EKEventStore()
    private var syncTimer: Timer?
    private var syncCount: Int = 0
    private var lastSyncAt: Double = 0
    private var lastError: String = ""
    private var isSyncing: Bool = false
    private var authorized: Bool = false

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            // EKEventStore.requestFullAccessToReminders must run on MainActor
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.main.async {
                    Task {
                        do {
                            let result = try await self.store.requestFullAccessToReminders()
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            authorized = granted
            return granted
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        self.authorized = granted
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    // MARK: - List Operations

    func getReminderLists() -> [ReminderListInfo] {
        let calendars = store.calendars(for: .reminder)
        return calendars.compactMap { cal -> ReminderListInfo? in
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: [cal]
            )
            // We cannot fetch synchronously inside an actor; return count as 0
            // and let callers use async variant for accurate counts.
            return ReminderListInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                reminderCount: 0,
                overdueCount: 0
            )
        }
    }

    func getReminderListsWithCounts() async -> [ReminderListInfo] {
        let calendars = store.calendars(for: .reminder)
        var results: [ReminderListInfo] = []

        for cal in calendars {
            let incomplete = await fetchReminders(matching: store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: [cal]
            ))
            let now = Date()
            let overdue = incomplete.filter { r in
                guard let due = r.dueDateComponents else { return false }
                guard let dueDate = Calendar.current.date(from: due) else { return false }
                return dueDate < now
            }
            results.append(ReminderListInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                reminderCount: incomplete.count,
                overdueCount: overdue.count
            ))
        }
        return results
    }

    func getReminders(from listName: String?) async -> [EKReminder] {
        let calendars = resolveCalendars(for: listName)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars
        )
        return await fetchReminders(matching: predicate)
    }

    // MARK: - Sync Operations

    func sync(todoService: TodoService, config: ServerConfig, overrideList: String? = nil) async {
        guard !isSyncing else { return }
        isSyncing = true

        do {
            if !authorized {
                let granted = try await requestAccess()
                guard granted else {
                    lastError = "未授权访问提醒事项"
                    isSyncing = false
                    return
                }
            }
            try await pushLocalChanges(todoService: todoService, config: config, overrideList: overrideList)
            try await pullRemoteChanges(todoService: todoService, config: config)
            lastSyncAt = Date().timeIntervalSince1970 * 1000
            lastError = ""
            syncCount += 1
        } catch {
            lastError = error.localizedDescription
        }

        isSyncing = false
    }

    func startPeriodicSync(todoService: TodoService, config: ServerConfig) async {
        stopPeriodicSync()

        // Request EventKit authorization before starting
        do {
            let granted = try await requestAccess()
            if !granted {
                lastError = "未授权访问提醒事项"
                return
            }
        } catch {
            lastError = "授权请求失败: \(error.localizedDescription)"
            return
        }

        let interval = max(5.0, Double(config.remindersPollSec))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.sync(todoService: todoService, config: config) }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer

        // Run initial sync immediately.
        Task { await sync(todoService: todoService, config: config) }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Status

    func getStatus(config: ServerConfig) -> RemindersSyncStatus {
        RemindersSyncStatus(
            enabled: config.remindersSyncEnabled,
            authorized: authorized,
            listName: config.remindersListName,
            pollSec: config.remindersPollSec,
            busy: isSyncing,
            lastSyncAt: lastSyncAt,
            lastError: lastError,
            syncCount: syncCount
        )
    }

    // MARK: - CRUD on Reminders

    func createReminder(title: String, dueDate: Date? = nil, listName: String? = nil) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemindersSyncError.titleRequired }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = resolveCalendars(for: listName).first ?? store.defaultCalendarForNewReminders()

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
        }

        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func deleteReminder(appleId: String) throws {
        guard let reminder = fetchReminder(by: appleId) else {
            throw RemindersSyncError.notFound(appleId)
        }
        try store.remove(reminder, commit: true)
    }

    // MARK: - Private: Push Local Changes

    private func pushLocalChanges(todoService: TodoService, config: ServerConfig, overrideList: String? = nil) async throws {
        let dirtyItems = await todoService.getDirtySyncItems()
        guard !dirtyItems.isEmpty else { return }

        let defaultList = overrideList ?? (config.remindersListName.isEmpty ? nil : config.remindersListName)

        for item in dirtyItems {
            do {
                if let appleId = item.appleId, !appleId.isEmpty {
                    if item.completed {
                        try deleteReminder(appleId: appleId)
                        continue
                    }
                    try editReminder(appleId: appleId, title: item.title)
                    await todoService.markItemSynced(id: item.id, service: .reminders, remoteId: appleId)
                } else if !item.completed {
                    let newId = try createReminder(
                        title: item.title,
                        dueDate: parseIsoDate(item.dueAt),
                        listName: defaultList
                    )
                    await todoService.markItemSynced(id: item.id, service: .reminders, remoteId: newId)
                }
            } catch {
                print("[RemindersSync] push failed for \(item.id): \(error)")
            }
        }
    }

    // MARK: - Private: Pull Remote Changes

    private func pullRemoteChanges(todoService: TodoService, config: ServerConfig) async throws {
        let reminders = await getReminders(
            from: config.remindersListName.isEmpty ? nil : config.remindersListName
        )
        let presentIds = reminders.map { $0.calendarItemIdentifier }

        for reminder in reminders {
            let dueDate = reminder.dueDateComponents.flatMap { components in
                Calendar.current.date(from: components)
            }
            await todoService.applyRemoteReminder(
                appleId: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                dueDate: dueDate.map(isoFromDate),
                completed: reminder.isCompleted
            )
        }

        await todoService.pruneRemoteMissingAppleIds(validIds: Set(presentIds))
    }

    // MARK: - Private: Reminder Helpers

    private func editReminder(appleId: String, title: String) throws {
        guard let reminder = fetchReminder(by: appleId) else {
            throw RemindersSyncError.notFound(appleId)
        }
        reminder.title = title
        try store.save(reminder, commit: true)
    }

    private func fetchReminder(by identifier: String) -> EKReminder? {
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        let semaphore = DispatchSemaphore(value: 0)
        var result: EKReminder?

        store.fetchReminders(matching: predicate) { reminders in
            result = reminders?.first { $0.calendarItemIdentifier == identifier }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func resolveCalendars(for listName: String?) -> [EKCalendar] {
        let all = store.calendars(for: .reminder)
        guard let listName, !listName.isEmpty else { return all }
        let matched = all.filter {
            $0.calendarIdentifier == listName ||
            $0.title.caseInsensitiveCompare(listName) == .orderedSame
        }
        return matched.isEmpty ? all : matched
    }

    // MARK: - Private: Date Helpers

    private func isoFromDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func parseIsoDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Errors

enum RemindersSyncError: LocalizedError {
    case titleRequired
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .titleRequired:
            "Reminder title is required"
        case .notFound(let id):
            "Reminder not found: \(id)"
        }
    }
}
