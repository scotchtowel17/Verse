import Foundation

/// Forward-migration chain for the persisted project model (Build Contract §10).
///
/// On open, if `schemaVersion < Schema.current`, raw JSON is migrated step by step before
/// decoding. Unknown future fields are preserved where feasible by operating on the raw
/// dictionary. Each migration is a pure `(from) -> to` transform on a JSON object.
///
/// Projects with `schemaVersion > Schema.current` are rejected. Loading them as v1 would
/// silently drop fields the newer app wrote, and re-saving would lock in that data loss.
public enum Migration {

    /// Inspect the raw JSON's `schemaVersion` and run forward migrations to the current schema.
    /// Returns JSON data ready to decode as the current `Project`.
    /// Throws if the file was written by a newer Verse than this one understands.
    public static func migrateRawIfNeeded(_ data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data // not an object; let the decoder produce a clean error
        }
        // Missing key defaults to v1 (oldest known). Wrong type is left for the decoder
        // so a string/bool schemaVersion cannot be "repaired" into a loadable project.
        let version: Int
        if let v = obj["schemaVersion"] as? Int {
            version = v
        } else if obj["schemaVersion"] == nil {
            version = 1
        } else {
            return data
        }
        if version > Schema.current {
            throw MigrationError.unsupportedFutureVersion(version)
        }
        guard version < Schema.current else { return data }

        var migrating = version
        while migrating < Schema.current {
            guard let step = steps[migrating] else {
                throw MigrationError.noPathFrom(migrating)
            }
            obj = try step(obj)
            migrating += 1
            obj["schemaVersion"] = migrating
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    /// Registered migration steps keyed by the *source* schema version.
    /// After each step, `migrateRawIfNeeded` sets `schemaVersion` to `source + 1`.
    static let steps: [Int: ([String: Any]) throws -> [String: Any]] = [
        1: { try v1ToV2($0) },
    ]

    /// v1 → v2: additive `Clip.mediaStartSeconds` (default 0). Existing clips had no file offset.
    private static func v1ToV2(_ obj: [String: Any]) throws -> [String: Any] {
        var result = obj
        guard var tracks = result["tracks"] as? [[String: Any]] else { return result }
        for ti in tracks.indices {
            guard var clips = tracks[ti]["clips"] as? [[String: Any]] else { continue }
            for ci in clips.indices {
                if clips[ci]["mediaStartSeconds"] == nil {
                    clips[ci]["mediaStartSeconds"] = 0.0
                }
            }
            tracks[ti]["clips"] = clips
        }
        result["tracks"] = tracks
        return result
    }

    public enum MigrationError: Error, LocalizedError, CustomStringConvertible {
        case noPathFrom(Int)
        /// Project was written by a newer Verse; refuse partial load (H2-MIG-1 / H4).
        case unsupportedFutureVersion(Int)

        public var description: String {
            switch self {
            case .noPathFrom(let v):
                return "No migration path from schemaVersion \(v) to \(Schema.current)."
            case .unsupportedFutureVersion(let v):
                return "This song was saved with a newer version of Verse (schema \(v)). Open it in an updated Verse."
            }
        }

        public var errorDescription: String? { description }
    }
}
