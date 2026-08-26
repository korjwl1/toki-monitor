import Foundation

// MARK: - A UserDefaults a test may safely write to
//
// The test target runs inside the app as its host, so `UserDefaults.standard`
// in a test IS the live `com.toki.monitor` domain holding the user's real
// dashboards, annotations and datasources. A previous session exercised a save
// path against it and destroyed the user's work. Nothing here ever writes
// through to a real domain.
//
// The obvious approach — `UserDefaults(suiteName: UUID().uuidString)`, torn
// down with `removePersistentDomain(forName:)` — is where the pile of stale
// `toki.monitor.tests.<uuid>.plist` files in ~/Library/Preferences came from.
// Emptying the domain does not remove the file, and deleting the file does not
// help either: cfprefsd still knows about the suite and writes an empty plist
// back out later in the run. Measured, not assumed — a run of these tests left
// 25 fresh 42-byte plists behind that way.
//
// So the store never reaches the preferences system at all. `ScratchDefaults`
// is a `UserDefaults` whose values live in a dictionary and die with the test.

/// A `UserDefaults` backed by memory. Every mutating entry point is overridden,
/// so nothing a store does can reach a real domain; the readers a store might
/// use are overridden too, so what it reads back is what it wrote.
///
/// Reads through an entry point not overridden here would fall through to the
/// app domain — harmless, since reading it changes nothing — but every *write*
/// is captured, which is the property that matters.
final class ScratchDefaults: UserDefaults, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    /// A fresh in-memory defaults for the duration of `body`.
    static func with<R>(_ body: (UserDefaults) throws -> R) rethrows -> R {
        try body(ScratchDefaults())
    }

    init() {
        // `suiteName: nil` gives an ordinary instance rather than the
        // `.standard` singleton. It is never consulted: every accessor below
        // reads and writes `storage`.
        super.init(suiteName: nil)!
    }

    // MARK: Reading

    override func object(forKey key: String) -> Any? {
        lock.withLock { storage[key] }
    }

    override func value(forKey key: String) -> Any? { object(forKey: key) }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? {
        object(forKey: key) as? [String: Any]
    }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func float(forKey key: String) -> Float { object(forKey: key) as? Float ?? 0 }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }

    // MARK: Writing
    //
    // Every `set` overload is here on purpose. `set(_:forKey:)` for Bool, Int,
    // Double, Float and URL are separate methods, not sugar over the `Any?`
    // one, so leaving any of them out would let that write reach a real domain.

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock {
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
    }

    override func setValue(_ value: Any?, forKey key: String) { set(value, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ url: URL?, forKey key: String) { set(url as Any?, forKey: key) }

    override func removeObject(forKey key: String) {
        lock.withLock { _ = storage.removeValue(forKey: key) }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock {
            for (key, value) in registrationDictionary where storage[key] == nil {
                storage[key] = value
            }
        }
    }

    override func synchronize() -> Bool { true }
}
