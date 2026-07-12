import Foundation

/// Minimal semantic-version utilities shared by the update checkers.
///
/// Centralizes the version-comparison logic that used to be duplicated, with
/// subtle differences, in `UpdateChecker` and `AboutPane`. Compares the numeric
/// MAJOR.MINOR.PATCH core and treats anything carrying a pre-release token as
/// "not an upgrade", with downgrade protection (equal or older → false).
enum SemVer {
    /// Pre-release markers that disqualify a tag from being offered as an update.
    static let preReleaseTokens = ["alpha", "beta", "rc", "dev", "pre", "snapshot"]

    /// Numeric (major, minor, patch) core of a version string.
    ///
    /// Strips a leading "v", build metadata ("+…"), a pre-release tail ("-…"),
    /// and a Homebrew revision suffix ("_N"), then reads up to three dotted
    /// integers. Non-numeric or missing components are treated as 0 (never
    /// crashes on a malformed tag).
    static func core(_ version: String) -> (Int, Int, Int) {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("v") { v.removeFirst() }
        v = String(v.split(separator: "+", maxSplits: 1).first ?? "")   // drop build metadata
        v = String(v.split(separator: "-", maxSplits: 1).first ?? "")   // drop pre-release tail
        v = String(v.split(separator: "_", maxSplits: 1).first ?? "")   // drop brew revision
        let parts = v.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    /// Major version only (used by the toki CLI compatibility gate).
    static func major(_ version: String) -> Int { core(version).0 }

    /// True if `version` carries a pre-release marker after a hyphen
    /// (e.g. "1.2.3-rc1"). A plain "1.2.3" is never a pre-release; matching only
    /// after the hyphen avoids false positives on substrings of the core.
    static func isPrerelease(_ version: String) -> Bool {
        guard let dash = version.firstIndex(of: "-") else { return false }
        let suffix = version[version.index(after: dash)...].lowercased()
        return preReleaseTokens.contains { suffix.hasPrefix($0) }
    }

    /// True only if `latest` is a stable release strictly newer than `current`.
    /// Pre-release `latest` is never an upgrade.
    static func isNewerStable(latest: String, current: String) -> Bool {
        if isPrerelease(latest) { return false }
        return core(latest) > core(current)
    }
}
