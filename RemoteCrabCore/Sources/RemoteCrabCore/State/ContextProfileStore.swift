import Foundation
import Observation

/// Owns everything that touches the disk. `ContextProfiles` stays pure so
/// its matching stays unit-testable without a filesystem.
///
/// A profile is executable input — it replays real key events into a
/// machine that already holds Accessibility permission — so a bad file
/// is rejected **loudly and individually**. Silently skipping it (or
/// half-reading it) is how a user ends up with a sheet that mysteriously
/// has fewer buttons and no explanation.
///
/// No network here. `ProfileSource.remote` is the declared seam a signed
/// feed will arrive through; nothing populates it today.
@Observable
public final class ContextProfileStore {

    public struct Problem: Equatable, Sendable {
        /// The file's name, so the message points at something the user
        /// can actually find and delete.
        public let file: String
        public let reason: String
    }

    public struct Loaded: Equatable, Sendable {
        public let profiles: [ContextProfile]
        public let problems: [Problem]
    }

    public enum LoadError: LocalizedError, Equatable {
        case newerSchema(found: Int, supported: Int)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .newerSchema(let found, let supported):
                return "This suite uses format version \(found); this version of RemoteCrab understands up to \(supported). Update RemoteCrab, or ask for a file from the version you have."
            case .malformed(let detail):
                return "This file could not be read: \(detail)"
            }
        }
    }

    /// `builtin < remote < userFile`, same id replaced outright.
    ///
    /// Replacement rather than first-match-wins is the whole point: under
    /// the old lookup an installed suite could never take effect, so
    /// dropping in a file changed nothing and said nothing.
    public static func merge(builtin: [ContextProfile],
                             user: [ContextProfile],
                             remote: [ContextProfile]) -> [ContextProfile] {
        var out = builtin
        for tier in [remote, user] {
            for profile in tier {
                out.removeAll { $0.id == profile.id }
                out.append(profile)
            }
        }
        return out
    }

    public private(set) var merged: [ContextProfile] = ContextProfiles.all
    /// Non-fatal, one per rejected file. Surfaced in the sheet so an
    /// ignored suite is visible instead of mysterious.
    public private(set) var problems: [Problem] = []

    /// `Documents/RemoteCrab/Profiles/*.json`, relative to Documents.
    public static let directoryName = "RemoteCrab/Profiles"

    public init() {}

    public static func decode(_ data: Data, from file: String) throws -> ContextProfile {
        // Peek the version before decoding so a newer file gets a
        // readable refusal instead of whatever the decoder makes of
        // fields it has never heard of.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["schemaVersion"] as? Int,
           version > ContextProfile.currentSchemaVersion {
            throw LoadError.newerSchema(found: version,
                                        supported: ContextProfile.currentSchemaVersion)
        }
        do {
            return try JSONDecoder().decode(ContextProfile.self, from: data)
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }
    }

    /// One bad file must not cost the user the good ones.
    public static func load(_ files: [(name: String, data: Data)]) -> Loaded {
        var profiles: [ContextProfile] = []
        var problems: [Problem] = []
        for file in files {
            do {
                let decoded = try decode(file.data, from: file.name)
                // Whatever came off disk is a user file by definition.
                // Stamping it here is what makes precedence work and lets
                // the sheet show where a button came from.
                profiles.append(ContextProfile(
                    schemaVersion: decoded.schemaVersion,
                    id: decoded.id,
                    title: decoded.title,
                    source: .userFile,
                    bundleIDs: decoded.bundleIDs,
                    actions: decoded.actions,
                    windowsProcessNames: decoded.windowsProcessNames,
                    windowsActions: decoded.windowsActions))
            } catch {
                problems.append(Problem(file: file.name,
                                        reason: (error as? LocalizedError)?.errorDescription
                                            ?? "\(error)"))
            }
        }
        return Loaded(profiles: profiles, problems: problems)
    }

    /// Re-reads the folder. Cheap enough to call whenever the sheet opens,
    /// which is what makes dropping in a file feel immediate.
    public func reload() {
        let fm = FileManager.default
        guard let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false) else {
            merged = ContextProfiles.all
            problems = []
            return
        }
        let directory = documents.appendingPathComponent(Self.directoryName)
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil) else {
            // No folder yet is the normal state, not a problem to report.
            merged = ContextProfiles.all
            problems = []
            return
        }
        let files: [(name: String, data: Data)] = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (url.lastPathComponent, data)
            }
        let result = Self.load(files)
        merged = Self.merge(builtin: ContextProfiles.all,
                            user: result.profiles,
                            remote: [])
        problems = result.problems
    }

    /// The folder a user drops files into, created on demand so the
    /// share sheet and Files app can find it.
    @discardableResult
    public static func ensureDirectory() -> URL? {
        let fm = FileManager.default
        guard let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true) else { return nil }
        let directory = documents.appendingPathComponent(directoryName)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}