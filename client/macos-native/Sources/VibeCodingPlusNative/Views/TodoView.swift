import SwiftUI
// MARK: - Todo

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var dueDate: Date?
    @State private var isEditingDate = false
    @State private var reminderListSelection: String = ""
    @State private var useReminderList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "TASKS",
                title: "待办",
                subtitle: state.inlineStatus,
                trailing: {
                    HStack(spacing: 8) {
                        if state.syncStatus?.enabled == true {
                            StatusBadge(text: "同步开启", active: true)
                        }
                        Text("\(state.todos.count) 进行中")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            )

            InkPanel(title: "新增待办", symbol: "plus.circle", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("输入待办内容，回车快速添加", text: $title)
                            .textFieldStyle(.plain)
                            .onSubmit { add() }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))

                        dueDateChip

                        Button { add() } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .inkProminentButton()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if state.syncStatus?.enabled == true || !state.reminderLists.isEmpty {
                        HStack(spacing: 12) {
                            Toggle("同步到提醒分组", isOn: $useReminderList)
                                .toggleStyle(InkCheckboxToggleStyle())
                            if useReminderList {
                                Picker("提醒分组", selection: $reminderListSelection) {
                                    Text("使用默认列表").tag("")
                                    ForEach(state.reminderLists) { list in
                                        Text("\(list.title) (\(list.reminderCount))").tag(list.title)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 300)
                                Button { Task { await state.runReminderSync() } } label: {
                                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .inkButton()
                            }
                            Spacer()
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                TodoSection(title: "进行中", items: state.todos, archived: false)
                TodoSection(title: "归档", items: state.archivedTodos, archived: true)
                    .frame(maxWidth: 380)
            }
        }
        .onAppear {
            Task { await state.fetchSyncLists() }
        }
    }

    private func add() {
        let value = title
        title = ""
        let dueISO = dueDate.map { ISO8601DateFormatter().string(from: $0) }
        dueDate = nil
        isEditingDate = false
        let listForSync = useReminderList ? (reminderListSelection.isEmpty ? nil : reminderListSelection) : nil
        Task { await state.addTodo(value, dueAt: dueISO, reminderList: listForSync) }
    }

    @ViewBuilder
    private var dueDateChip: some View {
        if isEditingDate {
            HStack(spacing: 6) {
                DatePicker("截止日期", selection: Binding(
                    get: { dueDate ?? Date() },
                    set: { dueDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .frame(width: 132)
                Button {
                    dueDate = nil
                    isEditingDate = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .inkIconButton()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.3), lineWidth: 1))
        } else if let date = dueDate {
            Button {
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(formatDate(date))
                        .font(.callout.weight(.medium))
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(InkTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                dueDate = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .inkIconButton()
        } else {
            Button {
                dueDate = Date()
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.caption)
                    Text("添加日期")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

struct TodoSection: View {
    let title: String
    let items: [TodoItem]
    let archived: Bool

    var body: some View {
        InkPanel(title: title, symbol: archived ? "archivebox" : "checklist", accessory: AnyView(
            Text("\(items.count)")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        )) {
            if items.isEmpty {
                Text(archived ? "暂无归档" : "暂无待办")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        TodoRow(item: item, archived: archived)
                    }
                }
            }
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var state: AppState
    let item: TodoItem
    var archived: Bool = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var isHovering = false

    var body: some View {
        InkCard(hoverable: true) {
            HStack(alignment: .center, spacing: 12) {
                if !archived {
                    Button {
                        Task { await state.setTodo(item, completed: !item.completed) }
                    } label: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(item.completed ? InkTheme.ink : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    TextField("", text: $editTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(InkTheme.ink.opacity(0.5), lineWidth: 1))
                        .onSubmit { saveEdit() }
                    Button("保存") { saveEdit() }.inkProminentButton()
                    Button("取消") { isEditing = false }.inkButton()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? .secondary : .primary)
                        HStack(spacing: 8) {
                            if let dueAt = item.dueAt, !dueAt.isEmpty {
                                Label(formatDueDate(dueAt), systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if item.appleId != nil {
                                Label("提醒", systemImage: "bell.fill")
                                    .font(.caption)
                                    .foregroundStyle(InkTheme.ink)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                if !isEditing {
                    HStack(spacing: 6) {
                        if !archived {
                            Button {
                                editTitle = item.title
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                            }
                            .inkIconButton()
                            .opacity(isHovering ? 1 : 0.5)
                        }
                        Button {
                            Task { await state.deleteTodo(item) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption.weight(.semibold))
                        }
                        .inkIconButton(danger: true)
                        .opacity(isHovering ? 1 : 0.5)
                    }
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private func saveEdit() {
        isEditing = false
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        Task { await state.editTodo(item, title: trimmed, dueAt: item.dueAt) }
    }

    private func formatDueDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}
