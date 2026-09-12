import Foundation
import Observation

/// `@Observable` cannot see `Self` in a stored-property initializer, so the key is file level.
private let lastSeenKey = "threadLastSeen"

/// The newest message the owner has looked at, per thread. The daemon keeps no read state, so this
/// lives in the app, keyed the way `ThreadSource` names a thread.
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

    func see(_ source: ThreadSource, through id: Int) {
        guard id > lastSeen(source) else { return }
        stored[source.key] = id
        defaults.set(stored, forKey: lastSeenKey)
    }
}
