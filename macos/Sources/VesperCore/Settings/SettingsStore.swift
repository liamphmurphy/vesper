import Foundation
import Observation


/// Reads and writes `<dataDir>/config.json` (desktop/src/config.ts). Only `native` and
/// `playgroundPorts` are interpreted; every other top-level key (serverUrl, localCheckoutPath, …)
/// is preserved byte-for-byte in meaning when the file is rewritten.
public enum ConfigFile {
    public static func url(dataDirectory: URL) -> URL { dataDirectory.appendingPathComponent("config.json") }

    public static func readDictionary(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    public static func normalizePlaygroundPorts(_ raw: Any?) -> [Int] {
        guard let list = raw as? [Any] else { return defaultPlaygroundPorts }
        var seen = Set<Int>()
        var out: [Int] = []
        for item in list {
            var n: Double?
            if let num = item as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                n = num.doubleValue
            } else if let s = item as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                n = d
            }
            guard let d = n, d == d.rounded(), d >= 1, d <= 65535 else { continue }
            if seen.insert(Int(d)).inserted { out.append(Int(d)) }
        }
        return out.isEmpty ? defaultPlaygroundPorts : out
    }

    public static func loadNative(from url: URL) -> NativeSettings {
        NativeSettings.normalize(readDictionary(at: url)["native"])
    }

    public static func loadPlaygroundPorts(from url: URL) -> [Int] {
        normalizePlaygroundPorts(readDictionary(at: url)["playgroundPorts"])
    }

    /// Replaces `native` (and optionally `playgroundPorts`), keeping every other key. Atomic.
    public static func save(native: NativeSettings, playgroundPorts: [Int]? = nil, to url: URL) throws {
        var dict = readDictionary(at: url)
        dict["native"] = native.jsonObject()
        if let ports = playgroundPorts { dict["playgroundPorts"] = normalizePlaygroundPorts(ports) }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try (data + Data("\n".utf8)).write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

/// The app's live settings. Mutate `settings` (or call `apply(patch:)`) and it is saved.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: NativeSettings
    public private(set) var playgroundPorts: [Int]
    public let configURL: URL

    public init(dataDirectory: URL) {
        configURL = ConfigFile.url(dataDirectory: dataDirectory)
        settings = ConfigFile.loadNative(from: configURL)
        playgroundPorts = ConfigFile.loadPlaygroundPorts(from: configURL)
    }

    public func reload() {
        settings = ConfigFile.loadNative(from: configURL)
        playgroundPorts = ConfigFile.loadPlaygroundPorts(from: configURL)
    }

    /// Applies a partial JSON patch (same shape as `native`), validates, saves, and returns the result.
    @discardableResult
    public func apply(patch: Any?) -> NativeSettings {
        settings = settings.applying(patch: patch)
        persist()
        return settings
    }

    /// Edits settings in place with a typed closure; the result is re-validated, then saved.
    @discardableResult
    public func update(_ edit: (inout NativeSettings) -> Void) -> NativeSettings {
        var copy = settings
        edit(&copy)
        settings = NativeSettings.normalize(copy.jsonObject(), base: settings)
        persist()
        return settings
    }

    private func persist() {
        try? ConfigFile.save(native: settings, to: configURL)
    }
}
