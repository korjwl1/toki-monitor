import Foundation

/// Decoding that survives one bad entry, for stores that write their whole
/// collection back.
///
/// The pattern this exists to stop has already cost this app three separate
/// data-loss bugs. A store decodes its array all-or-nothing, one entry it
/// cannot read makes the whole decode fail, the load returns empty, and the
/// next mutation writes that emptiness over everything the user had. The
/// caller cannot defend itself because it receives an empty collection either
/// way and has no way to tell "there is nothing" from "I could not read it".
///
/// It matters here specifically because none of this data can be rebuilt.
/// Events come back from provider logs; dashboards, annotations and
/// datasources were typed by hand and exist nowhere else.
enum LossTolerantStore {

    /// Decodes each element on its own, keeping the raw JSON of any that fail.
    static func decodeArray<T: Decodable>(
        _ type: T.Type, from data: Data
    ) -> (items: [T], unreadable: [Any]) {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return ([], [])
        }
        var items: [T] = []
        var unreadable: [Any] = []
        for element in raw {
            guard let bytes = try? JSONSerialization.data(withJSONObject: element),
                  let one = try? JSONDecoder().decode(T.self, from: bytes)
            else {
                unreadable.append(element)
                continue
            }
            items.append(one)
        }
        return (items, unreadable)
    }

    /// Re-encodes `items` and appends `unreadable` verbatim. Returns nil only
    /// when the items themselves cannot be encoded, in which case the caller
    /// must not write — replacing good bytes with nothing is the failure this
    /// whole type is about.
    static func encodeArray<T: Encodable>(_ items: [T], preserving unreadable: [Any]) -> Data? {
        guard let encoded = try? JSONEncoder().encode(items) else { return nil }
        guard !unreadable.isEmpty else { return encoded }
        guard var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any] else {
            return encoded
        }
        merged.append(contentsOf: unreadable)
        return (try? JSONSerialization.data(withJSONObject: merged)) ?? encoded
    }

    /// The dictionary form. One unreadable value costs its own key and nothing
    /// else; the raw values are kept so a save does not drop them.
    static func decodeDictionary<T: Decodable>(
        _ type: T.Type, from data: Data
    ) -> (items: [String: T], unreadable: [String: Any]) {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([:], [:])
        }
        var items: [String: T] = [:]
        var unreadable: [String: Any] = [:]
        for (key, value) in raw {
            guard let bytes = try? JSONSerialization.data(withJSONObject: value),
                  let one = try? JSONDecoder().decode(T.self, from: bytes)
            else {
                unreadable[key] = value
                continue
            }
            items[key] = one
        }
        return (items, unreadable)
    }

    static func encodeDictionary<T: Encodable>(
        _ items: [String: T], preserving unreadable: [String: Any]
    ) -> Data? {
        guard let encoded = try? JSONEncoder().encode(items) else { return nil }
        guard !unreadable.isEmpty else { return encoded }
        guard var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
            return encoded
        }
        for (key, value) in unreadable where merged[key] == nil { merged[key] = value }
        return (try? JSONSerialization.data(withJSONObject: merged)) ?? encoded
    }
}
