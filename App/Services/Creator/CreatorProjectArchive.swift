import Foundation

/// WMPKG001: bounded JSON manifest followed by raw, sorted file payloads (no Base64 or ZIP paths).
/// Only one validated wallpaper revision is exported. Conversation, settings and credentials are excluded.
enum CreatorProjectArchive {
    struct Entry: Codable, Equatable { let path: String; let bytes: Int; let digest: String }
    struct Header: Codable, Equatable { var version = 1; let entries: [Entry] }
    static let maximumBytes = CreatorMediaFile.maximumBundleBytes + 1024 * 1024
    static let magic = Data("WMPKG001".utf8)
    static func encode(_ snapshot: CreatorDraftStore.Snapshot) throws -> Data {
        let entries = snapshot.files.keys.sorted().map { Entry(path: $0, bytes: snapshot.files[$0]!.count, digest: CreatorPersistence.hash(snapshot.files[$0]!)) }
        let header = try CreatorPersistence.encode(Header(entries: entries))
        guard header.count <= 65536 else { throw CreatorPersistence.Failure.tooLarge }
        var result = magic
        let count = UInt32(header.count)
        for shift in [24, 16, 8, 0] { result.append(UInt8((count >> shift) & 255)) }
        result.append(header)
        for entry in entries { try Task.checkCancellation(); result.append(snapshot.files[entry.path]!) }
        guard result.count <= maximumBytes else { throw CreatorPersistence.Failure.tooLarge }
        return result
    }
    static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count > 12, data.count <= maximumBytes, data.prefix(8) == magic else { throw CreatorPersistence.Failure.invalidRecord }
        let count = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard (1...65536).contains(count), data.count >= 12 + count else { throw CreatorPersistence.Failure.invalidRecord }
        let bytes = data.subdata(in: 12..<12+count)
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        guard header.version == 1, (3...7).contains(header.entries.count), try CreatorPersistence.encode(header) == bytes,
              header.entries.map(\.path) == header.entries.map(\.path).sorted(), Set(header.entries.map(\.path)).count == header.entries.count else { throw CreatorPersistence.Failure.invalidRecord }
        var offset = 12 + count, files: [String: Data] = [:]
        for entry in header.entries {
            try Task.checkCancellation()
            guard entry.bytes > 0, entry.bytes <= CreatorMediaFile.maximumBytes, entry.bytes <= data.count-offset,
                  ["creator.json", "project.json", "index.html", "preview.jpg"].contains(entry.path) || entry.path.range(of: "^assets/[a-f0-9]{64}\\.(jpg|png|mp4|mov|m4v|webm)$", options: .regularExpression) != nil else { throw CreatorPersistence.Failure.invalidPath }
            let file = data.subdata(in: offset..<offset+entry.bytes)
            guard CreatorPersistence.hash(file) == entry.digest else { throw CreatorTemplate.Failure.changedContent }
            files[entry.path] = file; offset += entry.bytes
        }
        guard offset == data.count else { throw CreatorPersistence.Failure.invalidRecord }
        return files
    }
    static func snapshot(_ data: Data) throws -> CreatorDraftStore.Snapshot {
        let files = try decode(data), root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try CreatorBundleManifest.write(files, to: root)
        return try CreatorBundleManifest.read(root, scopedRevision: true)
    }
}
