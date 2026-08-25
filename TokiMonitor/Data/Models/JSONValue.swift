import Foundation

/// A JSON value this build has no type for.
///
/// It exists for one job: carrying keys written by a *newer* build of the app
/// through a load→save cycle untouched. Event data is disposable — the daemon
/// rebuilds it from provider logs — but a dashboard is not. The user made it by
/// hand, and an older build that drops the keys it does not recognise erases
/// them permanently the first time the user presses save (헌장 원칙 III,
/// `contracts/dashboard-json.md` C1).
///
/// Integers are kept apart from doubles deliberately: folding everything into
/// `Double` would rewrite `1` as `1` most of the time and lose precision above
/// 2^53, and "most of the time" is not a round-trip guarantee.
enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "value is not JSON"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case let .bool(v):     try c.encode(v)
        case let .int(v):      try c.encode(v)
        case let .double(v):   try c.encode(v)
        case let .string(v):   try c.encode(v)
        case let .array(v):    try c.encode(v)
        case let .object(v):   try c.encode(v)
        }
    }
}

/// A coding key with no fixed set of names, used to enumerate every key a
/// container actually holds — including the ones no `CodingKeys` case names.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    init(_ name: String) { stringValue = name }
}

// MARK: - Capture and replay

extension KeyedDecodingContainer where Key == DynamicCodingKey {
    /// Every key in this container whose name is not in `known`, decoded as
    /// opaque JSON.
    func unknownFields(besides known: Set<String>) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return out
    }
}

extension Decoder {
    /// Pull the keys this build has no field for out of the object currently
    /// being decoded. Call it from `init(from:)` after the known fields are read.
    func unknownFields(besides known: Set<String>) -> [String: JSONValue] {
        guard let c = try? container(keyedBy: DynamicCodingKey.self),
              let extras = try? c.unknownFields(besides: known)
        else { return [:] }
        return extras
    }
}

extension Encoder {
    /// Write preserved unknown keys back into the object being encoded.
    ///
    /// A key this build *does* understand is never taken from the preserved
    /// set: the live field wins, so an edit is never shadowed by a stale copy.
    func encodeUnknownFields(_ fields: [String: JSONValue], besides known: Set<String>) throws {
        guard !fields.isEmpty else { return }
        var c = container(keyedBy: DynamicCodingKey.self)
        // Sorted so the output is stable between runs; dictionaries are not.
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !known.contains(name) {
            try c.encode(value, forKey: DynamicCodingKey(name))
        }
    }
}
