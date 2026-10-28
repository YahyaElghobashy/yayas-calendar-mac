import Foundation

/// What may have changed in the data layer. Observers (meeting heads-up notifications, re-auth and
/// new-mail notices, the Deck export) re-read the store when told; the change itself carries no data.
enum DataChange: Equatable, Hashable, Sendable {
    /// A calendar pass ended (events, health or the last error may have moved) or an RSVP landed.
    case calendar
    /// Accounts were added, removed or edited (tag, health, calendar/mail switches).
    case accounts
    /// One account's mail pass ended.
    case mail(UUID)
}

/// The engine's observer list. Thread-safe; `post` runs every observer on the caller's thread, so an
/// observer only records the change and hands real work to its own queue.
final class DataObservers: @unchecked Sendable {
    typealias Observer = @Sendable (DataChange) -> Void

    private let lock = NSLock()
    private var observers: [(id: UUID, body: Observer)] = []

    @discardableResult
    func add(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers.append((id, observer))
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        observers.removeAll { $0.id == id }
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return observers.count }

    func post(_ change: DataChange) {
        lock.lock()
        let current = observers.map(\.body)
        lock.unlock()
        for observer in current { observer(change) }
    }
}
