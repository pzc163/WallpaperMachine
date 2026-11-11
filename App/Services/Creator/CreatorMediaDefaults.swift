import Foundation

enum CreatorMediaDefaults {
    static let hashes = [
        "night": "6a75b62d746c7b3a8e626a8b7d4af2469934fd651c45f77dc9b7db6b728f19f1",
        "lake": "c1bb5df8ab4b878e2b178a7221aec15698c5692e7a3f47a03c060f00b0d68a12",
        "forest": "409e87d47abca95f88e5c2d2139ca0b590b19ee3eb139ee6b29485e8693be742",
    ]
    static func binding(_ name: String) throws -> CreatorMediaBinding {
        guard let hash = hashes[name], let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "CreatorMedia") else { throw CreatorPersistence.Failure.invalidRecord }
        let bytes = try Data(contentsOf: url)
        guard CreatorPersistence.hash(bytes) == hash else { throw CreatorTemplate.Failure.changedContent }
        let media = try JSONDecoder().decode(CreatorMediaBinding.self, from: bytes)
        try media.validate(); return media
    }
    static func files(_ media: CreatorMediaBinding) throws -> [String: Data] {
        guard try hashes.keys.contains(where: { try binding($0) == media }) else { throw CreatorPersistence.Failure.invalidRecord }
        var files: [String: Data] = [:]
        for file in media.files {
            guard let url = Bundle.main.url(forResource: String(file.path.dropFirst(7)), withExtension: nil, subdirectory: "CreatorMedia") else { throw CreatorPersistence.Failure.invalidRecord }
            files[file.path] = try Data(contentsOf: url)
        }
        try CreatorPreparedMedia(binding: media, files: files).validate()
        return files
    }
}
