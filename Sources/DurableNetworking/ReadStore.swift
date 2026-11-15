import Foundation

/// Names one read in the store: a route and what picks one thing on it, such as `list/lst_abc`.
public struct InboxKey: Hashable, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ name: String) {
        description = name
    }

    /// A file name for any key, and a different one for each: everything but letters, digits, `-` and `.` is escaped.
    var fileName: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-.")
        return (description.addingPercentEncoding(withAllowedCharacters: allowed) ?? description) + ".json"
    }
}

/// The last good answer to a read, as the server sent it, and when.
public struct KeptAnswer: Equatable, Sendable {
    public let data: Data
    public let savedAt: Date

    public init(data: Data, savedAt: Date) {
        self.data = data
        self.savedAt = savedAt
    }
}

/// Last good answers on disk, one file per key. The file's modification date is when the server answered.
public struct ReadStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `nil` when nothing is kept, or the file can't be read yet (before the first unlock after a reboot).
    public func load(_ key: InboxKey) -> KeptAnswer? {
        let file = url(key)
        guard let data = try? Data(contentsOf: file),
              let savedAt = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        else {
            return nil
        }
        return KeptAnswer(data: data, savedAt: savedAt)
    }

    /// Only an answer that decoded comes here, so a captive portal's page never replaces good data.
    public func save(_ answer: KeptAnswer, for key: InboxKey) throws {
        let file = url(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // A push can arrive with the phone locked, and its reader wants this.
        try answer.data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try answer.data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.modificationDate: answer.savedAt], ofItemAtPath: file.path)
    }

    public func remove(_ key: InboxKey) {
        try? FileManager.default.removeItem(at: url(key))
    }

    func url(_ key: InboxKey) -> URL {
        directory.appending(path: key.fileName, directoryHint: .notDirectory)
    }
}
