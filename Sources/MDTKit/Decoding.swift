import Foundation

/// Dynamic decoding key, to read a manifest whose key names are not fixed at
/// compile time.
public struct AnyCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int? = nil

    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
    public init(_ name: String) { self.stringValue = name }
}

/// Decoding container that is lenient about the shape of keys.
///
/// Rationale: Galeax packagers already write `coreupdate_config.json` files in
/// PascalCase (`AppName`, `AppVersion`, `ProcessesToClose`). Requiring camelCase
/// here would impose a mental translation on every round-trip between the two
/// platforms, for zero benefit.
///
/// Normalization strips case and all separators, so `AppVersion`, `appVersion` and
/// `app_version` all designate the same entry. Aliases between genuinely different
/// names (`AppName` → `displayName`) are declared explicitly at the decoding site,
/// not guessed.
public struct LenientContainer {

    private let container: KeyedDecodingContainer<AnyCodingKey>
    private let index: [String: AnyCodingKey]

    public init(_ decoder: Decoder) throws {
        self.container = try decoder.container(keyedBy: AnyCodingKey.self)
        var index: [String: AnyCodingKey] = [:]
        for key in container.allKeys {
            // First occurrence wins: if a manifest contains both `appName` and
            // `AppName`, we do not want the traversal order to silently decide the
            // winner on each run.
            let normalized = LenientContainer.normalize(key.stringValue)
            if index[normalized] == nil { index[normalized] = key }
        }
        self.index = index
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func resolve(_ names: [String]) -> AnyCodingKey? {
        for name in names {
            if let key = index[LenientContainer.normalize(name)] { return key }
        }
        return nil
    }

    /// Decodes the first key found among `names`. `nil` if none is present.
    public func decode<T: Decodable>(_ type: T.Type, _ names: String...) throws -> T? {
        guard let key = resolve(names) else { return nil }
        return try container.decodeIfPresent(type, forKey: key)
    }

    public func require<T: Decodable>(_ type: T.Type, _ names: String...) throws -> T {
        guard let key = resolve(names),
              let value = try container.decodeIfPresent(type, forKey: key)
        else {
            throw ManifestError.malformed("required key missing: \(names.first ?? "?")")
        }
        return value
    }

    public func contains(_ names: String...) -> Bool { resolve(names) != nil }
}
