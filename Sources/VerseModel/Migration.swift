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
        var version = (obj["schemaVersion"] as? Int) ?? 1
        if version > Schema.current {
            throw MigrationError.unsupportedFutureVersion(version)
        }
        guard version < Schema.current else { return data }

        while version < Schema.current {
            guard let step = steps[version] else {
                throw MigrationError.noPathFrom(version)
            }
            obj = try step(obj)
            version += 1
            obj["schemaVersion"] = version
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    /// Registered migration steps keyed by the *source* schema version.
    /// (None yet — v1 is the initial schema. Add `1: { v1ToV2($0) }` etc. as the schema evolves.)
    static let steps: [Int: ([String: Any]) throws -> [String: Any]] = [:]

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
