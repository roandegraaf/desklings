import Foundation
import Observation

/// `@Observable` cannot see `Self` in a stored-property initializer, so the key is file level.
private let lastSeenKey = "threadLastSeen"

/// The newest message the owner has looked at, per thread, keyed the way `ThreadSource` names a
/// thread. The daemon holds the shared copy; this one is cached so a launch draws dots before the
/// first poll lands.
///
/// A thread nobody has opened is entirely unread: there is no message id at or below zero, so the
/// missing entry needs no case of its own and the dot and the divider read the same rule.
@Observable
final class Unread {
    @ObservationIgnored private let defaults: UserDefaults
    private var stored: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.dictionary(forKey: lastSeenKey) as? [String: Int] ?? [:]
    }

    func lastSeen(_ source: ThreadSource) -> Int {
        stored[source.key] ?? 0
    }

    func has(_ source: ThreadSource, newest: Int?) -> Bool {
        guard let newest else { return false }
        return newest > lastSeen(source)
    }

    /// Whether the mark moved, so the caller knows to tell the daemon.
    @discardableResult
    func see(_ source: ThreadSource, through id: Int) -> Bool {
        guard id > lastSeen(source) else { return false }
        stored[source.key] = id
        defaults.set(stored, forKey: lastSeenKey)
        return true
    }

    func adopt(_ marks: [String: Int]) {
        let merged = stored.merging(marks, uniquingKeysWith: max)
        guard merged != stored else { return }
        stored = merged
        defaults.set(stored, forKey: lastSeenKey)
    }
}
