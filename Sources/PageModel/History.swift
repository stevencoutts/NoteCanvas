/// Snapshot-based undo/redo. `State` is a value type, so a snapshot is just a copy.
public struct History<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call with the state as it was *before* a change.
    public mutating func record(_ before: State) {
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Drops the newest undo snapshot (for a change that is being silently reverted). Leaves redo alone.
    public mutating func discardLast() { _ = undoStack.popLast() }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
