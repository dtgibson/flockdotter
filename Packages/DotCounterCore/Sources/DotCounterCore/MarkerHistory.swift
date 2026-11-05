import Foundation

public enum RenumberOrder: String, CaseIterable, Sendable {
    case leftToRight, topToBottom, nearestNeighbor
}

/// Value-based command history stores changed markers or UUID order, never image data
/// or full count snapshots. The workspace owns the live value; background work
/// may prepare an isolated capture for guarded atomic installation.
public struct MarkerHistory: Sendable {
    public private(set) var markers: [Marker]
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []
    private let limit = 1000

    private enum Command: Sendable {
        case insert(Marker, Int)
        case remove(Marker, Int)
        case move(before: Marker, after: Marker)
        case reorder(before: [UUID], after: [UUID])
        case batch([Marker], Int, removing: Bool)

        var inverse: Command {
            switch self {
            case let .insert(marker, index): .remove(marker, index)
            case let .remove(marker, index): .insert(marker, index)
            case let .move(before, after): .move(before: after, after: before)
            case let .reorder(before, after): .reorder(before: after, after: before)
            case let .batch(markers, index, removing): .batch(markers, index, removing: !removing)
            }
        }
    }

    public init(markers: [Marker] = []) { self.markers = markers }

    /// Validate the complete batch before changing count, redo or history.
    @discardableResult public mutating func appendBatch(markers additions: [Marker]) -> Bool {
        guard !additions.isEmpty, additions.count <= 10_000,
              additions.count <= ResourceLimits.maxMarkers - markers.count else { return false }
        var identities = Set(markers.map(\.id))
        for marker in additions {
            guard (try? marker.validate()) != nil, identities.insert(marker.id).inserted else { return false }
        }
        commit(.batch(additions, markers.count, removing: false))
        return true
    }

    @discardableResult public mutating func add(x: Double, y: Double) -> Bool {
        guard markers.count < ResourceLimits.maxMarkers else { return false }
        let marker = Marker(x: x, y: y)
        guard (try? marker.validate()) != nil else { return false }
        commit(.insert(marker, markers.count))
        return true
    }

    @discardableResult public mutating func delete(id: UUID) -> Bool {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return false }
        commit(.remove(markers[index], index))
        return true
    }

    @discardableResult public mutating func move(id: UUID, x: Double, y: Double) -> Bool {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return false }
        let after = Marker(id: id, x: x, y: y)
        guard (try? after.validate()) != nil, markers[index] != after else { return false }
        commit(.move(before: markers[index], after: after))
        return true
    }

    @discardableResult public mutating func renumber(_ order: RenumberOrder) -> Bool {
        // Nearest Neighbor requires upright dimensions and the asynchronous path.
        guard order != .nearestNeighbor else { return false }
        let before = markers.map(\.id)
        let after = markers.enumerated().sorted { a, b in
            let primaryA = order == .leftToRight ? a.element.x : a.element.y
            let primaryB = order == .leftToRight ? b.element.x : b.element.y
            if primaryA != primaryB { return primaryA < primaryB }
            let secondaryA = order == .leftToRight ? a.element.y : a.element.x
            let secondaryB = order == .leftToRight ? b.element.y : b.element.x
            if secondaryA != secondaryB { return secondaryA < secondaryB }
            return a.offset < b.offset
        }.map { $0.element.id }
        guard before != after else { return false }
        commit(.reorder(before: before, after: after))
        return true
    }

    /// Validate and prepare a complete computed order before mutating anything.
    /// Intended for a background value copy, followed by guarded atomic installation.
    @discardableResult public mutating func applyPermutation(
        _ indices: [Int], cancellation: NearestNeighborCancellation = .init()
    ) throws -> Bool {
        try cancellation.checkCancellation()
        guard indices.count == markers.count else {
            throw CountError.invalid("Renumbering must include every marker exactly once.")
        }
        var work = WorkCheck(cancellation: cancellation)
        var seen = Set<Int>()
        seen.reserveCapacity(indices.count)
        var before: [UUID] = [], after: [UUID] = []
        var reordered: [Marker] = []
        before.reserveCapacity(indices.count); after.reserveCapacity(indices.count)
        reordered.reserveCapacity(indices.count)
        var changed = false
        for (offset, index) in indices.enumerated() {
            try work.step()
            guard markers.indices.contains(index), seen.insert(index).inserted else {
                throw CountError.invalid("Renumbering must include every marker exactly once.")
            }
            changed = changed || offset != index
            before.append(markers[offset].id)
            let marker = markers[index]
            after.append(marker.id)
            reordered.append(marker)
        }
        try cancellation.checkCancellation()
        guard changed else { return false }
        // All throwing work precedes this point. Avoid a second dictionary/lookup
        // pass through commit/apply; this is the same single reorder command.
        markers = reordered
        undoStack.append(.reorder(before: before, after: after))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll(keepingCapacity: true)
        return true
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        apply(command.inverse)
        redoStack.append(command)
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        apply(command)
        undoStack.append(command)
        return true
    }

    private mutating func commit(_ command: Command) {
        apply(command)
        undoStack.append(command)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll(keepingCapacity: true)
    }

    private mutating func apply(_ command: Command) {
        switch command {
        case let .insert(marker, index): markers.insert(marker, at: index)
        case let .remove(_, index): markers.remove(at: index)
        case let .move(_, after):
            if let index = markers.firstIndex(where: { $0.id == after.id }) { markers[index] = after }
        case let .reorder(_, after):
            let lookup = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0) })
            markers = after.compactMap { lookup[$0] }
        case let .batch(batch, index, removing):
            if removing { markers.removeSubrange(index..<(index + batch.count)) }
            else { markers.insert(contentsOf: batch, at: index) }
        }
    }
}
