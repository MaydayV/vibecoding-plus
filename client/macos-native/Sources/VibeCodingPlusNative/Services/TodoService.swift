import Foundation

// MARK: - Constants

private let todoFileVersion = 1

private let defaultTodoTitles = [
    "示例：按住 BOOT 说\"添加计划 喝水\"",
    "示例：UP/DN 移动选中项",
    "示例：短按 BOOT 完成或删除当前计划",
    "示例：双击 UP 切换 Todo / Live"
]

// MARK: - Todo Item Data

struct TodoItemData: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var completed: Bool
    var createdAt: Double       // epoch ms
    var updatedAt: Double       // epoch ms
    var completedAt: Double?    // epoch ms
    var dueAt: String?          // ISO 8601
    var source: String?         // "local", "seed", "apple"
    var appleId: String?
    var syncUpdatedAt: Double?  // epoch ms — last Apple Reminders sync time
    var dirty: Bool             // needs sync to Reminders
}

// MARK: - Todo Snapshot

struct TodoServiceSnapshot: Sendable {
    var items: [TodoItemData]
    var archiveItems: [TodoItemData]
    var selectedIndex: Int
    var lastActionText: String
}

// MARK: - Persisted State (Codable)

private struct PersistedState: Codable {
    var version: Int
    var items: [TodoItemData]
    var archiveItems: [TodoItemData]
    var selectedIndex: Int
}

// MARK: - TodoService

actor TodoService {

    // MARK: - State

    private var items: [TodoItemData] = []
    private var archiveItems: [TodoItemData] = []
    private var selectedIndex: Int = 0
    private var lastActionText: String = ""
    private let storagePath: String
    private var onChange: (() -> Void)?

    // MARK: - Init

    /// Creates a new TodoService, loading persisted state from disk.
    static func create(storagePath: String) async -> TodoService {
        let service = TodoService(storagePath: storagePath)
        await service.loadFromDisk()
        return service
    }

    private init(storagePath: String) {
        self.storagePath = storagePath
    }

    // MARK: - Callback

    func setOnChange(_ handler: @escaping () -> Void) {
        self.onChange = handler
    }

    // MARK: - CRUD

    func create(title: String, dueAt: String? = nil) -> TodoItemData {
        let now = epochMs()
        let item = TodoItemData(
            id: makeId(),
            title: title,
            completed: false,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            dueAt: dueAt,
            source: "local",
            appleId: nil,
            syncUpdatedAt: nil,
            dirty: true
        )
        items.append(item)
        selectedIndex = items.count - 1
        lastActionText = "已添加计划 \(items.count)"
        save()
        emitChange()
        return item
    }

    func update(id: String? = nil, index: Int? = nil, title: String? = nil, dueAt: String? = nil) {
        guard let resolvedIndex = tryResolveIndex(id: id, index: index) else { return }

        if let title {
            items[resolvedIndex].title = title
        }
        if let dueAt {
            items[resolvedIndex].dueAt = dueAt.isEmpty ? nil : dueAt
        }
        items[resolvedIndex].updatedAt = epochMs()
        items[resolvedIndex].source = "local"
        items[resolvedIndex].dirty = true
        selectedIndex = resolvedIndex
        lastActionText = "已更新计划 \(resolvedIndex + 1)"
        save()
        emitChange()
    }

    func toggle(id: String? = nil, index: Int? = nil, completed: Bool) {
        guard let resolvedIndex = tryResolveIndex(id: id, index: index) else { return }
        let now = epochMs()

        if completed {
            // Move to archive
            var item = items.remove(at: resolvedIndex)
            item.completed = true
            item.completedAt = now
            item.updatedAt = now
            item.source = "local"
            item.dirty = true
            archiveItems.insert(item, at: 0)
            lastActionText = "已完成计划 \(resolvedIndex + 1)"
        } else {
            // Restore from archive — find by id
            let targetId = id ?? (index != nil ? nil : items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil)
            if let targetId, let archiveIndex = archiveItems.firstIndex(where: { $0.id == targetId }) {
                var item = archiveItems.remove(at: archiveIndex)
                item.completed = false
                item.completedAt = nil
                item.updatedAt = now
                item.source = "local"
                item.dirty = true
                items.append(item)
                selectedIndex = items.count - 1
                lastActionText = "已恢复计划"
            } else if items.indices.contains(resolvedIndex) {
                items[resolvedIndex].completed = false
                items[resolvedIndex].completedAt = nil
                items[resolvedIndex].updatedAt = now
                items[resolvedIndex].source = "local"
                items[resolvedIndex].dirty = true
                selectedIndex = resolvedIndex
                lastActionText = "已恢复计划 \(resolvedIndex + 1)"
            }
        }

        clampSelectedIndex()
        save()
        emitChange()
    }

    @discardableResult
    func delete(id: String? = nil, index: Int? = nil) -> [TodoItemData] {
        guard let resolvedIndex = tryResolveIndex(id: id, index: index) else { return [] }
        let removed = items.remove(at: resolvedIndex)
        if items.isEmpty {
            selectedIndex = -1
        } else {
            selectedIndex = min(resolvedIndex, items.count - 1)
        }
        lastActionText = "已删除计划 \(resolvedIndex + 1)"
        save()
        emitChange()
        return [removed]
    }

    func selectNext() {
        guard !items.isEmpty else {
            lastActionText = "暂无计划"
            return
        }
        selectedIndex = (selectedIndex + 1) % items.count
        lastActionText = "当前计划 \(selectedIndex + 1)"
        save()
    }

    func selectPrev() {
        guard !items.isEmpty else {
            lastActionText = "暂无计划"
            return
        }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        lastActionText = "当前计划 \(selectedIndex + 1)"
        save()
    }

    func clearCompleted() {
        archiveItems.removeAll()
        lastActionText = "已清空已完成计划"
        save()
        emitChange()
    }

    // MARK: - Query

    func getSnapshot() -> TodoServiceSnapshot {
        TodoServiceSnapshot(
            items: items,
            archiveItems: archiveItems,
            selectedIndex: clampIndex(selectedIndex),
            lastActionText: lastActionText
        )
    }

    func getAppleLinkedItemsByIds(_ ids: [String]) -> [TodoItemData] {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return [] }
        return items.filter { idSet.contains($0.id) && ($0.appleId?.isEmpty == false) }
    }

    func getDirtySyncItems() -> [TodoItemData] {
        items.filter { item in
            let src = item.source ?? "local"
            if src == "seed" { return false }
            guard let appleId = item.appleId, !appleId.isEmpty else {
                return src == "local"
            }
            // Has appleId: dirty if local changes newer than last sync
            if src == "local" { return true }
            let updatedAt = item.updatedAt
            let syncedAt = item.syncUpdatedAt ?? 0
            return updatedAt > syncedAt
        }
    }

    // MARK: - Reminders Integration

    func applyRemoteReminder(appleId: String, title: String, dueDate: String?, completed: Bool) {
        let now = epochMs()

        // Find existing item by appleId
        if let idx = items.firstIndex(where: { $0.appleId == appleId }) {
            items[idx].title = title
            items[idx].completed = completed
            items[idx].dueAt = dueDate
            items[idx].source = "apple"
            items[idx].updatedAt = now
            items[idx].syncUpdatedAt = now
            if completed {
                items[idx].completedAt = now
            } else {
                items[idx].completedAt = nil
            }
            items[idx].dirty = false
            lastActionText = "苹果待办已同步"
            clampSelectedIndex()
            save()
            emitChange()
            return
        }

        // Also check archive
        if let idx = archiveItems.firstIndex(where: { $0.appleId == appleId }) {
            archiveItems[idx].title = title
            archiveItems[idx].completed = completed
            archiveItems[idx].dueAt = dueDate
            archiveItems[idx].source = "apple"
            archiveItems[idx].updatedAt = now
            archiveItems[idx].syncUpdatedAt = now
            archiveItems[idx].completedAt = completed ? now : nil
            archiveItems[idx].dirty = false

            // If uncompleted, move back to active
            if !completed {
                var item = archiveItems.remove(at: idx)
                item.completed = false
                item.completedAt = nil
                items.append(item)
            }
            lastActionText = "苹果待办已同步"
            clampSelectedIndex()
            save()
            emitChange()
            return
        }

        // Create new item from remote
        var item = TodoItemData(
            id: makeId(),
            title: title,
            completed: completed,
            createdAt: now,
            updatedAt: now,
            completedAt: completed ? now : nil,
            dueAt: dueDate,
            source: "apple",
            appleId: appleId,
            syncUpdatedAt: now,
            dirty: false
        )
        if completed {
            archiveItems.insert(item, at: 0)
        } else {
            items.append(item)
            if selectedIndex < 0 { selectedIndex = 0 }
        }
        lastActionText = "苹果待办已同步"
        save()
        emitChange()
    }

    func markItemSynced(id: String, appleId: String) {
        let now = epochMs()
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].appleId = appleId
            items[idx].source = "apple"
            items[idx].syncUpdatedAt = now
            items[idx].dirty = false
            save()
            return
        }
        if let idx = archiveItems.firstIndex(where: { $0.id == id }) {
            archiveItems[idx].appleId = appleId
            archiveItems[idx].source = "apple"
            archiveItems[idx].syncUpdatedAt = now
            archiveItems[idx].dirty = false
            save()
        }
    }

    func pruneRemoteMissingAppleIds(validIds: Set<String>) {
        let before = items.count + archiveItems.count
        items.removeAll { item in
            guard let appleId = item.appleId, !appleId.isEmpty else { return false }
            if item.source == "local" { return false }
            return !validIds.contains(appleId)
        }
        archiveItems.removeAll { item in
            guard let appleId = item.appleId, !appleId.isEmpty else { return false }
            if item.source == "local" { return false }
            return !validIds.contains(appleId)
        }
        guard items.count + archiveItems.count != before else { return }
        clampSelectedIndex()
        lastActionText = "苹果待办已同步"
        save()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let fm = FileManager.default
        guard !storagePath.isEmpty, fm.fileExists(atPath: storagePath) else {
            seedDefaults()
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            items = state.items
            archiveItems = state.archiveItems
            selectedIndex = clampIndex(state.selectedIndex)
        } catch {
            backupCorruptFile()
            seedDefaults()
        }
    }

    func save() {
        let state = PersistedState(
            version: todoFileVersion,
            items: items,
            archiveItems: archiveItems,
            selectedIndex: clampIndex(selectedIndex)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            let dir = (storagePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            // Atomic write: temp file then rename
            let tempPath = "\(storagePath).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).tmp"
            try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
            try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: storagePath),
                withItemAt: URL(fileURLWithPath: tempPath)
            )
        } catch {
            print("[TodoService] save failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func seedDefaults() {
        let now = epochMs()
        items = defaultTodoTitles.map { title in
            TodoItemData(
                id: makeId(),
                title: title,
                completed: false,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                dueAt: nil,
                source: "seed",
                appleId: nil,
                syncUpdatedAt: nil,
                dirty: false
            )
        }
        archiveItems = []
        selectedIndex = 0
        save()
    }

    private func backupCorruptFile() {
        let fm = FileManager.default
        guard !storagePath.isEmpty, fm.fileExists(atPath: storagePath) else { return }
        let backupPath = "\(storagePath).corrupt-\(Int(Date().timeIntervalSince1970 * 1000))"
        try? fm.moveItem(atPath: storagePath, toPath: backupPath)
    }

    private func emitChange() {
        onChange?()
    }

    /// Resolve an item index from an explicit id, a 1-based user index, or the current selection.
    private func tryResolveIndex(id: String?, index: Int?) -> Int? {
        guard !items.isEmpty else {
            assertionFailure("todo_empty")
            return nil
        }

        // Prefer id lookup
        if let id, !id.isEmpty {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                assertionFailure("todo_item_not_found: \(id)")
                return nil
            }
            return idx
        }

        // 1-based user-facing index
        if let index {
            let zeroBased = index - 1
            guard zeroBased >= 0, zeroBased < items.count else {
                assertionFailure("todo_index_out_of_range: \(index)")
                return nil
            }
            return zeroBased
        }

        // Fall back to selected index
        guard selectedIndex >= 0, selectedIndex < items.count else {
            assertionFailure("todo_index_required")
            return nil
        }
        return selectedIndex
    }

    private func clampIndex(_ idx: Int) -> Int {
        if items.isEmpty { return -1 }
        return min(max(idx, 0), items.count - 1)
    }

    private func clampSelectedIndex() {
        selectedIndex = clampIndex(selectedIndex)
    }

    private func makeId() -> String {
        UUID().uuidString.lowercased()
    }

    private func epochMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}
