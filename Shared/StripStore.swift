import Foundation
import os
import Security

/// A strip saved by the host app for the widget to read.
struct CachedStrip {
    var pageURL: URL
    var day: Date
    var imageData: Data
    var usedPreviousDay: Bool
    var fetchedAt: Date
}

struct StripAttempt: Codable {
    var at: Date
    var securedToday: Bool
}

enum StripStoreError: Error {
    case noContainer
}

/// Shared folder for the app and the widget.
///
/// Entitlements list `$(TeamIdentifierPrefix)$(APP_GROUP_SUFFIX)`. Codesign turns that
/// into the Team ID, a dot, and the suffix (`com.example.CalvinWidget.shared` unless
/// the bundle prefix was changed). The container root often fails `isWritableFile`
/// even when `Library/Application Support` inside it can be written, so the strip is
/// saved in that Application Support directory.
enum StripStore {
    /// App Group id without the team prefix. Matches `APP_GROUP_SUFFIX` from the xcconfig,
    /// which the build writes into the `CalvinGroupSuffix` Info.plist entry.
    static let groupSuffix: String = {
        let fallback = "com.example.CalvinWidget.shared"
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CalvinGroupSuffix") as? String else {
            return fallback
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") {
            return fallback
        }
        return trimmed
    }()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.CalvinWidget",
        category: "fetch"
    )
    private static var signingFailure = "not checked"

    private static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
    static let homeURL = URL(string: "https://www.gocomics.com/calvinandhobbes")!

    private static let imageName = "strip.jpg"
    private static let metaName = "strip.json"
    private static let attemptName = "attempt.json"
    private static var resolvedContainer: URL?

    static func pageURL(for day: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let dayNumber = parts.day ?? 1
        let address = String(
            format: "https://www.gocomics.com/calvinandhobbes/%04d/%02d/%02d",
            year,
            month,
            dayNumber
        )
        return URL(string: address) ?? homeURL
    }

    static func load() -> CachedStrip? {
        guard let folder = containerURL() else { return nil }
        let imageURL = folder.appendingPathComponent(imageName)
        let metaURL = folder.appendingPathComponent(metaName)
        guard let imageData = try? Data(contentsOf: imageURL),
              let metaData = try? Data(contentsOf: metaURL),
              let record = try? JSONDecoder().decode(OnDiskStrip.self, from: metaData),
              let day = date(fromDayString: record.day),
              let pageURL = URL(string: record.pageURL) else {
            return nil
        }
        return CachedStrip(
            pageURL: pageURL,
            day: day,
            imageData: imageData,
            usedPreviousDay: record.usedPreviousDay,
            fetchedAt: record.fetchedAt
        )
    }

    static func save(_ strip: CachedStrip) throws {
        guard let folder = containerURL() else { throw StripStoreError.noContainer }
        let imageURL = folder.appendingPathComponent(imageName)
        let metaURL = folder.appendingPathComponent(metaName)
        let record = OnDiskStrip(
            pageURL: strip.pageURL.absoluteString,
            day: dayString(strip.day),
            usedPreviousDay: strip.usedPreviousDay,
            fetchedAt: strip.fetchedAt
        )
        let meta = try JSONEncoder().encode(record)
        try strip.imageData.write(to: imageURL, options: .atomic)
        try meta.write(to: metaURL, options: .atomic)
    }

    static func lastAttempt() -> StripAttempt? {
        guard let folder = containerURL() else { return nil }
        let url = folder.appendingPathComponent(attemptName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StripAttempt.self, from: data)
    }

    static func recordAttempt(_ attempt: StripAttempt) {
        guard let folder = containerURL(),
              let data = try? JSONEncoder().encode(attempt) else { return }
        try? data.write(to: folder.appendingPathComponent(attemptName), options: .atomic)
    }

    static var accessDescription: String {
        let tried = candidateIdentifiers().joined(separator: ", ")
        return "The shared folder for the widget isn't writable (tried \(tried)). See the fetch log for the containerURL path, directory error, and probe write."
    }

    // MARK: - Container

    static func containerURL() -> URL? {
        if let resolvedContainer { return resolvedContainer }
        note("signing \(signingSummary())")
        note("container candidates=\(candidateIdentifiers().joined(separator: " | "))")
        var usable: [URL] = []
        for identifier in candidateIdentifiers() {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                note("containerURL nil id=\(identifier)")
                continue
            }
            note("containerURL id=\(identifier) path=\(url.path)")
            let created = createDirectoryNote(at: url)
            let writable = FileManager.default.isWritableFile(atPath: url.path)
            note("createDirectory id=\(identifier) result=\(created) isWritable=\(writable)")
            let support = url.appendingPathComponent("Library/Application Support", isDirectory: true)
            if let folder = usableFolder(support, identifier: "\(identifier) Application Support") {
                usable.append(folder)
            }
            if let folder = usableFolder(url, identifier: identifier) {
                usable.append(folder)
            }
        }
        let chosen = usable.first { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(metaName).path)
        } ?? usable.first
        if let chosen {
            note("container chosen path=\(chosen.path)")
        } else {
            note("container unavailable")
        }
        resolvedContainer = chosen
        return chosen
    }

    private static func usableFolder(_ directory: URL, identifier: String) -> URL? {
        let created = createDirectoryNote(at: directory)
        let writable = FileManager.default.isWritableFile(atPath: directory.path)
        let probe = directory.appendingPathComponent(".write-probe")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            note("probe write ok id=\(identifier) path=\(directory.path) isWritable=\(writable) mkdir=\(created)")
            return directory
        } catch {
            note("probe write failed id=\(identifier) path=\(directory.path) isWritable=\(writable) mkdir=\(created) error=\(errorText(error))")
        }
        let imagePath = directory.appendingPathComponent(imageName).path
        let metaPath = directory.appendingPathComponent(metaName).path
        if FileManager.default.isReadableFile(atPath: imagePath) || FileManager.default.isReadableFile(atPath: metaPath) {
            note("probe unwritable but strip is readable id=\(identifier) path=\(directory.path)")
            return directory
        }
        return nil
    }

    private static func createDirectoryNote(at url: URL) -> String {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return "ok"
        } catch {
            return errorText(error)
        }
    }

    private static func errorText(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
    }

    private static func signingSummary() -> String {
        guard let dictionary = signingDictionary() else {
            return "dictionary unavailable \(signingFailure) profileTeam=\(teamIdentifierFromProfile() ?? "nil")"
        }
        let team = dictionary[kSecCodeInfoTeamIdentifier] as? String ?? "nil"
        let groups = entitledGroupIdentifiers().joined(separator: "|")
        let appID = applicationIdentifier(in: dictionary) ?? "nil"
        return "team=\(team) appID=\(appID) groups=\(groups.isEmpty ? "none" : groups) profileTeam=\(teamIdentifierFromProfile() ?? "nil")"
    }

    private static func applicationIdentifier(in dictionary: NSDictionary) -> String? {
        guard let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? NSDictionary else { return nil }
        return entitlements["com.apple.application-identifier"] as? String
    }

    static func candidateIdentifiers() -> [String] {
        var identifiers: [String] = []
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !identifiers.contains(trimmed) else { return }
            identifiers.append(trimmed)
        }
        // Prefer the id actually written into the signature, after Xcode expands the team prefix.
        for group in entitledGroupIdentifiers() {
            append(group)
        }
        if let team = teamIdentifier(), !team.isEmpty {
            append("\(team).\(groupSuffix)")
        }
        if let appID = signingDictionary().flatMap({ applicationIdentifier(in: $0) }),
           let team = appID.split(separator: ".").first,
           !team.isEmpty {
            append("\(team).\(groupSuffix)")
        }
        append(groupSuffix)
        return identifiers
    }

    static func teamIdentifier() -> String? {
        if let dictionary = signingDictionary(),
           let team = dictionary[kSecCodeInfoTeamIdentifier] as? String,
           !team.isEmpty {
            return team
        }
        return teamIdentifierFromProfile()
    }

    private static func entitledGroupIdentifiers() -> [String] {
        guard let dictionary = signingDictionary(),
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? NSDictionary,
              let groups = entitlements["com.apple.security.application-groups"] else {
            return []
        }
        if let array = groups as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    private static func signingDictionary() -> NSDictionary? {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard selfStatus == errSecSuccess, let code else {
            signingFailure = "SecCodeCopySelf \(selfStatus)"
            return nil
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            signingFailure = "SecCodeCopyStaticCode \(staticStatus)"
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: 1 << 1) // kSecCSSigningInformation
        let infoStatus = SecCodeCopySigningInformation(staticCode, flags, &information)
        guard infoStatus == errSecSuccess, let information else {
            signingFailure = "SecCodeCopySigningInformation \(infoStatus)"
            return nil
        }
        signingFailure = ""
        return information as NSDictionary
    }

    private static func teamIdentifierFromProfile() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        guard let key = text.range(of: "<key>TeamIdentifier</key>") else { return nil }
        let rest = text[key.upperBound...]
        guard let open = rest.range(of: "<string>"),
              let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex) else {
            return nil
        }
        let team = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return team.isEmpty ? nil : team
    }

    // MARK: - Dates

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayString string: String, calendar: Calendar = .current) -> Date? {
        let pieces = string.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        var components = DateComponents()
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        return calendar.date(from: components)
    }
}

private struct OnDiskStrip: Codable {
    var pageURL: String
    var day: String
    var usedPreviousDay: Bool
    var fetchedAt: Date
}
