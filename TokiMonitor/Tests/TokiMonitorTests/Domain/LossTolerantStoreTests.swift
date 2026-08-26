import Foundation
import Testing
@testable import TokiMonitor

/// `LossTolerantStore` is the shared answer to a bug that shipped four times in
/// this app under four different names: a store decodes its collection
/// all-or-nothing, one entry it cannot read fails the whole decode, the load
/// returns empty, and the next mutation writes that emptiness over everything
/// the user had.
///
/// Every one of those four went in with a full green suite, because nothing
/// ever fed a store an entry it could not read. That is what is here.
///
/// The tests are deliberately about the two halves separately — what a decode
/// keeps, and what an encode is allowed to drop — because the loss only
/// happens when both halves agree that the bad entry does not exist.
@Suite("Loss-tolerant decode and encode")
struct LossTolerantStoreTests {

    /// A small Codable with one required field of a specific type, so an entry
    /// can be made unreadable by a type mismatch rather than by malformed JSON.
    /// That is the shape the real failures take: valid JSON written by a build
    /// that disagrees about a field.
    private struct Item: Codable, Equatable {
        var id: String
        var count: Int
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data) -> Any {
        try! JSONSerialization.jsonObject(with: data)
    }

    private func encoded(_ item: Item) -> [String: Any] {
        object(try! JSONEncoder().encode(item)) as! [String: Any]
    }

    /// Valid JSON this build cannot decode into `Item`: `count` is a string.
    private func futureItem(id: String, note: String = "written by a later build") -> [String: Any] {
        ["id": id, "count": "seventeen", "note": note]
    }

    // MARK: - Array: decoding

    @Test("one unreadable element costs that element and nothing else")
    func arrayPartialDecode() {
        let data = json([
            encoded(Item(id: "a", count: 1)),
            futureItem(id: "b"),
            encoded(Item(id: "c", count: 3)),
        ])

        let result = LossTolerantStore.decodeArray(Item.self, from: data)

        // The whole point: the two readable items are NOT collateral damage.
        #expect(result.items == [Item(id: "a", count: 1), Item(id: "c", count: 3)])
        #expect(result.unreadable.count == 1)
    }

    @Test("every element unreadable is still not a crash, and still not silent")
    func arrayAllUnreadable() {
        let data = json([futureItem(id: "a"), futureItem(id: "b")])

        let result = LossTolerantStore.decodeArray(Item.self, from: data)

        // `items` is empty either way; `unreadable` is the only thing that
        // tells the caller "there is data here I could not read", and it is
        // what stops the save path from writing over it.
        #expect(result.items.isEmpty)
        #expect(result.unreadable.count == 2)
    }

    @Test("data that is not a JSON array at all yields empty rather than crashing")
    func arrayNotAnArray() {
        for data in [json(["k": "v"]), Data("not json at all".utf8), Data()] {
            let result = LossTolerantStore.decodeArray(Item.self, from: data)
            #expect(result.items.isEmpty)
            #expect(result.unreadable.isEmpty)
        }
    }

    // MARK: - Array: round trip

    @Test("an unreadable element survives decode→encode with its values intact")
    func arrayRoundTripPreservesValues() throws {
        let original = futureItem(id: "b", note: "a field this build has no property for")
        let data = json([encoded(Item(id: "a", count: 1)), original])

        let decoded = LossTolerantStore.decodeArray(Item.self, from: data)
        let out = LossTolerantStore.encodeArray(decoded.items, preserving: decoded.unreadable)

        let elements = object(try #require(out)) as! [Any]
        #expect(elements.count == 2)

        // "Present" is not the bar. If the entry came back as an empty object,
        // or with `count` coerced to 0 by a re-encode through `Item`, the user
        // has lost the entry just as thoroughly as if it were deleted — it
        // would decode into a later build as something it never was.
        let survivor = elements.compactMap { $0 as? [String: Any] }
            .first { $0["id"] as? String == "b" }
        let kept = try #require(survivor)
        #expect(kept["count"] as? String == "seventeen")
        #expect(kept["note"] as? String == "a field this build has no property for")
    }

    @Test("a second round trip does not erode what the first one preserved")
    func arrayRepeatedRoundTripIsStable() throws {
        var data = json([encoded(Item(id: "a", count: 1)), futureItem(id: "b")])

        // Three loads and three saves, as three ordinary edits would do.
        for _ in 0..<3 {
            let decoded = LossTolerantStore.decodeArray(Item.self, from: data)
            data = try #require(LossTolerantStore.encodeArray(decoded.items, preserving: decoded.unreadable))
        }

        let final = LossTolerantStore.decodeArray(Item.self, from: data)
        #expect(final.items == [Item(id: "a", count: 1)])
        #expect(final.unreadable.count == 1)
        let kept = try #require(final.unreadable.first as? [String: Any])
        #expect(kept["count"] as? String == "seventeen")
    }

    // MARK: - Array: encoding refuses rather than writes nothing

    @Test("an encode failure returns nil so the caller can decline to write")
    func arrayEncodeFailureReturnsNil() {
        // Returning empty Data here instead of nil is the bug in miniature:
        // the caller would write it, and every good entry on disk would be
        // gone. nil is the only value that lets `save` refuse.
        let out = LossTolerantStore.encodeArray([Double.nan], preserving: [])
        #expect(out == nil)
    }

    @Test("an encode failure returns nil even when there is unreadable data to protect")
    func arrayEncodeFailureWithUnreadable() {
        let out = LossTolerantStore.encodeArray([Double.nan], preserving: [futureItem(id: "b")])
        #expect(out == nil)
    }

    @Test("nothing to preserve encodes to the plain array")
    func arrayNoUnreadable() throws {
        let items = [Item(id: "a", count: 1), Item(id: "b", count: 2)]
        let out = try #require(LossTolerantStore.encodeArray(items, preserving: []))
        #expect(LossTolerantStore.decodeArray(Item.self, from: out).items == items)
    }

    // MARK: - Dictionary

    @Test("an unreadable value costs its key only")
    func dictionaryPartialDecode() {
        let data = json([
            "alpha": encoded(Item(id: "a", count: 1)),
            "beta": futureItem(id: "b"),
            "gamma": encoded(Item(id: "c", count: 3)),
        ])

        let result = LossTolerantStore.decodeDictionary(Item.self, from: data)

        #expect(result.items == ["alpha": Item(id: "a", count: 1), "gamma": Item(id: "c", count: 3)])
        #expect(Array(result.unreadable.keys) == ["beta"])
    }

    @Test("data that is not a JSON object at all yields empty rather than crashing")
    func dictionaryNotAnObject() {
        for data in [json([1, 2, 3]), Data("not json at all".utf8), Data()] {
            let result = LossTolerantStore.decodeDictionary(Item.self, from: data)
            #expect(result.items.isEmpty)
            #expect(result.unreadable.isEmpty)
        }
    }

    @Test("an unreadable value survives decode→encode with its values intact")
    func dictionaryRoundTripPreservesValues() throws {
        let data = json([
            "alpha": encoded(Item(id: "a", count: 1)),
            "beta": futureItem(id: "b", note: "kept verbatim"),
        ])

        let decoded = LossTolerantStore.decodeDictionary(Item.self, from: data)
        let out = LossTolerantStore.encodeDictionary(decoded.items, preserving: decoded.unreadable)

        let dict = object(try #require(out)) as! [String: Any]
        #expect(dict.count == 2)
        let kept = try #require(dict["beta"] as? [String: Any])
        #expect(kept["count"] as? String == "seventeen")
        #expect(kept["note"] as? String == "kept verbatim")
    }

    @Test("a preserved key never overwrites a live one")
    func dictionaryLiveKeyWins() throws {
        // The user replaced the entry under "beta" with something this build
        // can read. The stale raw value must not come back on top of it —
        // re-appending it would undo the edit the user just made, silently.
        let out = LossTolerantStore.encodeDictionary(
            ["beta": Item(id: "b", count: 42)],
            preserving: ["beta": futureItem(id: "b")]
        )

        let dict = object(try #require(out)) as! [String: Any]
        let beta = try #require(dict["beta"] as? [String: Any])
        #expect(beta["count"] as? Int == 42)
        #expect(beta["note"] == nil)
    }

    @Test("an encode failure returns nil so the caller can decline to write")
    func dictionaryEncodeFailureReturnsNil() {
        #expect(LossTolerantStore.encodeDictionary(["a": Double.nan], preserving: [:]) == nil)
        #expect(
            LossTolerantStore.encodeDictionary(
                ["a": Double.nan], preserving: ["beta": futureItem(id: "b")]
            ) == nil
        )
    }
}
