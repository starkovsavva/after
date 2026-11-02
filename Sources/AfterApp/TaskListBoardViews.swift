import AfterLocalization
import AfterCore
import SwiftUI

struct TaskStatusMark: View {
    let status: TaskWorkspaceStatus
    var body: some View {
        Image(systemName: status.symbol).font(.system(size: 16))
            .foregroundStyle(status == .done ? Ink.green : status == .blocked ? Ink.warning : status == .doing ? Ink.accent : Color.secondary)
            .accessibilityLabel(L(status.title))
    }
}

struct TaskListPane: View {
    @ObservedObject var notes: NotesStore
    let tasks: [TaskWorkspace]
    let hasAnyTasks: Bool
    var draftKey = "newtask"
    @Binding var query: String
    let select: (TaskWorkspace) -> Void
    let addTask: () -> Void
    let changeStatus: (TaskWorkspace, TaskWorkspaceStatus) -> Void
    private var selection: Binding<String?> {
        Binding(get: { notes.selectedTaskID }, set: { id in
            if let id, let task = tasks.first(where: { $0.id == id }) { select(task) }
        })
    }
    private var newTask: Binding<String> { Binding(get: { notes.captureDrafts[draftKey] ?? "" }, set: { notes.captureDrafts[draftKey] = $0 }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Найти задачу…"), text: $query).textFieldStyle(.plain).accessibilityIdentifier("tasks.search")
            }.afterSearchFieldSurface().padding(12)
            HStack {
                Text(L("Задачи")).font(AppTypography.captionStrong)
                Spacer(); Text("\(tasks.count)").font(AppTypography.caption).monospacedDigit()
            }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
            List(selection: selection) {
                ForEach(tasks) { task in
                    row(task).tag(task.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityIdentifier("tasks.list")
                .overlay(alignment: .top) {
                    if tasks.isEmpty {
                        Text(hasAnyTasks ? L("Нет подходящих задач") : L("Здесь пока нет задач"))
                            .foregroundStyle(.secondary).font(AppTypography.control).padding(24).allowsHitTesting(false)
                    }
                }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField(L("Новая задача"), text: newTask).textFieldStyle(.plain).onSubmit(addTask).accessibilityIdentifier("tasks.new-text")
                Button(action: addTask) { Image(systemName: "arrow.up.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled(newTask.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(L("Добавить задачу")).accessibilityIdentifier("tasks.new-submit")
            }.padding(12)
        }.background(Ink.field.opacity(0.3))
    }
    private func row(_ task: TaskWorkspace) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button { changeStatus(task, task.status == .done ? .todo : .done) } label: {
                TaskStatusMark(status: task.status).frame(width: 24, height: 24)
            }.buttonStyle(.plain).accessibilityLabel((task.status == .done ? L("Вернуть в работу: ") : L("Завершить задачу: ")) + task.title)
            Button { select(task) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(notes.selectedTaskID == task.id ? AppTypography.controlStrong : AppTypography.control)
                        .lineLimit(2).strikethrough(task.status == .done).frame(maxWidth: .infinity, alignment: .leading)
                    TaskRowMetadata(task: task)
                }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("tasks.row." + task.id)
                .accessibilityAddTraits(notes.selectedTaskID == task.id ? .isSelected : [])
                .accessibilityValue(notes.selectedTaskID == task.id ? L("Выбрана") : "")
        }.padding(10)
    }
}

struct TaskRowMetadata: View {
    let task: TaskWorkspace
    var body: some View {
        HStack(spacing: 6) {
            Text(L(task.source.title)).lineLimit(1)
            if !task.due.isEmpty { Text("·").accessibilityHidden(true); Text(TaskDueDate.display(task.due, reference: task.createdAt > 0 ? Date(timeIntervalSince1970: task.createdAt) : nil)).lineLimit(1) }
        }.font(AppTypography.caption).foregroundStyle(.secondary)
    }
}

struct TaskBoardView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localDragSession = TaskBoardDragSession()
    @State private var dropTarget: TaskWorkspaceStatus?
    @State private var columnFrames: [TaskWorkspaceStatus: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var pointerDrag: TaskBoardPointerDrag?
    @State private var pointerCancelled = false
    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var edgeScrollDirection = 0
    @GestureState private var pointerDragging = false
    @State private var coordinateSpace = UUID()
    let tasks: [TaskWorkspace]
    let selectedID: String?
    let select: (TaskWorkspace) -> Void
    let changeStatus: (TaskWorkspace, TaskWorkspaceStatus) -> Void
    var suppliedDragSession: TaskBoardDragSession? = nil
    private var dragSession: TaskBoardDragSession { suppliedDragSession ?? localDragSession }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(TaskWorkspaceStatus.allCases) { status in column(status).id(status) }
                }.padding(AppLayout.contentInset)
            }.background(Ink.soft)
                .coordinateSpace(name: coordinateSpace)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TaskBoardViewportPreference.self, value: geometry.size)
                })
                .onPreferenceChange(TaskBoardColumnFramePreference.self) { frames in
                    columnFrames = frames
                    if let drag = pointerDrag { dropTarget = pointerTarget(drag.location) }
                    updateEdgeScroll(proxy)
                }
                .onPreferenceChange(TaskBoardViewportPreference.self) { viewportSize = $0; updateEdgeScroll(proxy) }
                .boardDropTargetGeometry("tasks.board.viewport")
                .overlay(alignment: .topLeading) {
                    if let drag = pointerDrag {
                        cardContents(drag.task).frame(width: 236)
                            .boardDropTargetGeometry("tasks.board.drag-preview")
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                            .position(x: min(max(drag.location.x + 70, 126), max(126, viewportSize.width - 126)),
                                      y: min(max(drag.location.y + 20, 50), max(50, viewportSize.height - 50)))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onChange(of: pointerDragging) { _, dragging in
                    if !dragging { clearPointerDrag(); pointerCancelled = false }
                }
                .onChange(of: pointerDrag?.location) { _, _ in updateEdgeScroll(proxy) }
                .onExitCommand {
                    if pointerDrag != nil { pointerCancelled = true; clearPointerDrag() }
                }
                .onDisappear { clearPointerDrag() }
        }
    }
    private func column(_ status: TaskWorkspaceStatus) -> some View {
        columnContents(status)
            .padding(8).frame(width: 252)
            .frame(minHeight: 220, maxHeight: .infinity, alignment: .top)
            .background(dropTarget == status ? Ink.accent.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: AppLayout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: AppLayout.cardRadius)
                .stroke(dropTarget == status ? Ink.accent.opacity(0.65) : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.cardRadius))
            .boardDropTargetGeometry("tasks.board.column." + status.rawValue)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: TaskBoardColumnFramePreference.self,
                                       value: [status: geometry.frame(in: .named(coordinateSpace))])
            })
            .onDrop(of: [TaskBoardDragSession.type.identifier], delegate: TaskBoardColumnDropDelegate(
                session: dragSession, status: status, app: app, isTargeted: targetBinding(status)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L(status.title))
            .accessibilityIdentifier("tasks.board.column." + status.rawValue)
    }
    private func columnContents(_ status: TaskWorkspaceStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHeader(status)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tasks.filter { $0.status == status }) { task in cardButton(task) }
                }.padding(2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func columnHeader(_ status: TaskWorkspaceStatus) -> some View {
        HStack(spacing: 7) {
            TaskStatusMark(status: status)
            Text(L(status.title)).font(AppTypography.controlStrong)
            Spacer(minLength: 4)
            Text("\(tasks.filter { $0.status == status }.count)")
                .font(AppTypography.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 4)
    }
    private func cardButton(_ task: TaskWorkspace) -> some View {
        Button { select(task) } label: {
            cardContents(task).contentShape(RoundedRectangle(cornerRadius: AppLayout.cardRadius))
        }
            .buttonStyle(.plain).accessibilityIdentifier("tasks.board." + task.id)
            .accessibilityAddTraits(selectedID == task.id ? .isSelected : [])
            .accessibilityValue(selectedID == task.id ? L("Выбрана") : "")
            .boardDropTargetGeometry("tasks.board." + task.id)
            .opacity(pointerDrag?.task.id == task.id ? 0.35 : 1)
            // One board-local pointer gesture distinguishes a click from a move.
            // Keep one private reference from first movement through canonical CAS.
            .highPriorityGesture(pointerGesture(task))
            .contextMenu {
                ForEach(TaskWorkspaceStatus.allCases) { target in
                    Button(L(target.title)) { changeStatus(task, target) }.disabled(target == task.status)
                }
            }
    }
    private func pointerGesture(_ task: TaskWorkspace) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .updating($pointerDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard !pointerCancelled else { return }
                if pointerDrag == nil {
                    pointerDrag = TaskBoardPointerDrag(task: task, provider: dragSession.provider(for: task, app: app),
                                                       location: value.location)
                } else { pointerDrag?.location = value.location }
                dropTarget = pointerTarget(value.location)
            }
            .onEnded { value in
                let drag = pointerDrag
                let target = pointerCancelled ? nil : pointerTarget(value.location)
                clearPointerDrag()
                guard let drag, drag.task.id == task.id, let target else { return }
                dragSession.receive([drag.provider], target: target, app: app)
            }
    }
    private func pointerTarget(_ point: CGPoint) -> TaskWorkspaceStatus? {
        guard CGRect(origin: .zero, size: viewportSize).contains(point) else { return nil }
        return TaskWorkspaceStatus.allCases.first { columnFrames[$0]?.contains(point) == true }
    }
    private func clearPointerDrag() {
        stopEdgeScroll()
        pointerDrag = nil; dropTarget = nil
    }
    private func stopEdgeScroll() {
        edgeScrollTask?.cancel(); edgeScrollTask = nil; edgeScrollDirection = 0
    }
    private func edgeDirection() -> Int {
        guard !pointerCancelled, let point = pointerDrag?.location,
              CGRect(origin: .zero, size: viewportSize).contains(point) else { return 0 }
        if point.x < 30 { return -1 }
        if point.x > viewportSize.width - 30 { return 1 }
        return 0
    }
    private func nextOffscreenColumn(_ direction: Int) -> TaskWorkspaceStatus? {
        let statuses = TaskWorkspaceStatus.allCases
        if direction > 0 {
            return statuses.first { (columnFrames[$0]?.maxX ?? 0) > viewportSize.width + 1 }
        }
        return statuses.reversed().first { (columnFrames[$0]?.minX ?? 0) < -1 }
    }
    private func updateEdgeScroll(_ proxy: ScrollViewProxy) {
        let direction = edgeDirection()
        guard direction != 0, nextOffscreenColumn(direction) != nil else { stopEdgeScroll(); return }
        guard edgeScrollTask == nil || edgeScrollDirection != direction else { return }
        stopEdgeScroll()
        edgeScrollDirection = direction
        // Holding still at an edge continues revealing columns without requiring
        // more mouse events. Cancelled gestures never retain a scrolling task.
        edgeScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard !Task.isCancelled else { return }
                guard edgeDirection() == direction, let target = nextOffscreenColumn(direction) else {
                    stopEdgeScroll(); return
                }
                if reduceMotion { proxy.scrollTo(target, anchor: direction > 0 ? .trailing : .leading) }
                else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: direction > 0 ? .trailing : .leading)
                    }
                }
            }
        }
    }
    private func targetBinding(_ status: TaskWorkspaceStatus) -> Binding<Bool> {
        Binding(get: { dropTarget == status }, set: { targeted in
            if targeted { dropTarget = status } else if dropTarget == status { dropTarget = nil }
        })
    }
    private func cardContents(_ task: TaskWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title).font(AppTypography.controlStrong).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            TaskRowMetadata(task: task)
            if !task.project.isEmpty { Text(task.project).font(AppTypography.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: AppLayout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: AppLayout.cardRadius).stroke(selectedID == task.id ? Ink.accent.opacity(0.45) : Ink.line, lineWidth: 1))
    }
}


private struct TaskBoardPointerDrag {
    let task: TaskWorkspace
    let provider: NSItemProvider
    var location: CGPoint
}
private struct TaskBoardColumnFramePreference: PreferenceKey {
    static var defaultValue: [TaskWorkspaceStatus: CGRect] = [:]
    static func reduce(value: inout [TaskWorkspaceStatus: CGRect], nextValue: () -> [TaskWorkspaceStatus: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
private struct TaskBoardViewportPreference: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Siblings without the measurement contribute the zero default. They
        // must not erase the viewport published by its background GeometryReader.
        if next.width > 0 && next.height > 0 { value = next }
    }
}


extension View {
    /// Measures the exact drop surface only during the disposable native board check.
    @ViewBuilder func boardDropTargetGeometry(_ identifier: String) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-task-workspace") {
            self.background(TaskBoardDropGeometryProbe(identifier: identifier)
                .allowsHitTesting(false).accessibilityHidden(true))
        } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit

private struct TaskBoardDropGeometryProbe: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> TaskBoardDropGeometryView {
        let view = TaskBoardDropGeometryView()
        view.identifier = NSUserInterfaceItemIdentifier("geometry." + identifier)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: TaskBoardDropGeometryView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("geometry." + identifier)
    }
}

private final class TaskBoardDropGeometryView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
