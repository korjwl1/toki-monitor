import Foundation

/// Resolves a toki "project" string (which may be a real path *or*
/// Claude Code's hyphen-escaped form of one) to a human-readable folder
/// name, with disk-existence checks to pick the right joiner.
///
/// Previously lived as a `static` on `DashboardViewModel`. It has nothing
/// to do with the ViewModel — it's a stateless filesystem lookup with a
/// cache. Moving it out of the VM trims a chunk of unrelated code and
/// makes it testable.
enum ProjectNameResolver {
    /// Bounded cache so repeated lookups for the same path skip the
    /// filesystem hits. NSCache evicts under memory pressure; capped at
    /// 256 entries to keep the working set predictable.
    // NSCache is thread-safe per Apple's docs; Swift 6 doesn't model it as
    // Sendable in the stdlib bridging, so we mark this unchecked.
    private nonisolated(unsafe) static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    /// Extract last folder name from a toki project path.
    /// Claude Code encodes paths with `-` instead of `/`. We split on `-`
    /// then greedily rebuild the real path, trying `/`, `-`, `_` as
    /// joiners until we land on a folder that actually exists on disk.
    static func cleanProjectName(_ raw: String) -> String {
        let key = raw as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }
        let result = resolve(raw)
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func resolve(_ raw: String) -> String {
        if raw.contains("/") {
            return URL(fileURLWithPath: raw).lastPathComponent
        }

        let segments = raw.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard segments.count > 1 else { return raw }

        let fm = FileManager.default
        var basePath = ""
        var projectStartIdx = 0

        // Build base path by consuming segments as directory levels
        for (i, segment) in segments.enumerated() {
            let candidate = basePath.isEmpty ? "/" + segment : basePath + "/" + segment
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                basePath = candidate
                projectStartIdx = i + 1
            } else {
                break
            }
        }

        // Remaining segments form the project name — try to find it on disk
        guard projectStartIdx < segments.count else {
            return URL(fileURLWithPath: basePath).lastPathComponent
        }

        let remaining = Array(segments[projectStartIdx...])

        // Greedily accumulate remaining segments, trying -, _ joiners to match a real folder
        var projectName = remaining[0]
        for seg in remaining.dropFirst() {
            let candidates = [
                (basePath + "/" + projectName + "-" + seg, projectName + "-" + seg),
                (basePath + "/" + projectName + "_" + seg, projectName + "_" + seg),
            ]
            var found = false
            for (path, name) in candidates {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    projectName = name
                    found = true
                    break
                }
            }
            if !found {
                let subPath = basePath + "/" + projectName
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                    basePath = subPath
                    projectName = seg
                } else {
                    projectName += "-" + seg
                }
            }
        }

        return projectName
    }
}
