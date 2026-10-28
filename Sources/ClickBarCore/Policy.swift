import Foundation

public enum IconGroup: String, CaseIterable, Codable, Sendable {
    case always, single, double
    public var title: String {
        switch self {
        case .always: "Always visible"
        case .single: "Single click"
        case .double: "Double click"
        }
    }
}

public enum RevealState: Int, Sendable {
    case collapsed, single, all
    public var title: String {
        switch self {
        case .collapsed: "Panel closed"
        case .single: "Single-click group"
        case .all: "All hidden groups"
        }
    }
    public func clicked(count: Int) -> Self {
        if count >= 2 { return self == .all ? .collapsed : .all }
        return self == .single ? .collapsed : .single
    }
}

public enum VisibilityPolicy {
    /// Opening the lower panel must never reveal hidden apps on the main bar.
    public static func hiddenOnMenuBar(running: Set<String>, groups: [String: IconGroup], ownID: String) -> Set<String> {
        hidden(running: running, groups: groups, state: .collapsed, ownID: ownID)
    }

    public static func panelMembers(running: Set<String>, groups: [String: IconGroup],
                                    state: RevealState, ownID: String) -> Set<String> {
        Set(running.filter { id in
            guard id != ownID else { return false }
            switch groups[id] ?? .always {
            case .always: return false
            case .single: return state != .collapsed
            case .double: return state == .all
            }
        })
    }

    public static func hidden(running: Set<String>, groups: [String: IconGroup],
                              state: RevealState, ownID: String) -> Set<String> {
        Set(running.filter { id in
            guard id != ownID else { return false }
            switch groups[id] ?? .always {
            case .always: return false
            case .single: return state == .collapsed
            case .double: return state != .all
            }
        })
    }

    public static func allowing(running: Set<String>, hidden: Set<String>, ownID: String) -> Set<String> {
        running.subtracting(hidden).union([ownID])
    }
}

/// A deterministic click recognizer: a double click never emits a single click first.
/// The UI supplies the OS double-click interval and schedules flush() at the deadline.
public struct ClickRecognizer {
    public private(set) var deadline: Double?
    public init() {}
    public mutating func receive(count: Int, now: Double, interval: Double) -> Int? {
        // MenuBarAgent can forward two physical clicks as count=1 twice. Pair
        // actions by monotonic time instead of relying on that forwarded count.
        if count == 2 || (count == 1 && deadline.map { now <= $0 } == true) {
            deadline = nil
            return 2
        }
        guard count == 1 else { return nil }
        deadline = now + interval
        return nil
    }
    public mutating func flush(now: Double) -> Int? {
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil
        return 1
    }
    public mutating func cancel() { deadline = nil }
}
