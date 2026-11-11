import Foundation

/// Bundled artwork and exact core references; view code never opens these files.
enum CreatorMasterCatalog {
    struct Master: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let engine: CreatorEngine
        let keywords: [String]
        let parameters: CreatorParameterSchema
        let file: String
        let sha256: String
        var mediaName: String? = nil
        func source() throws -> String {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "CreatorMasters") else { throw CreatorPersistence.Failure.invalidRecord }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= CreatorCodeOutput.maximumSourceBytes, CreatorPersistence.hash(bytes) == sha256,
                  let source = String(data: bytes, encoding: .utf8) else { throw CreatorPersistence.Failure.invalidRecord }
            if engine == .htmlCanvas { try CreatorCodeOutput.validateHTML(bytes); return source }
            var document = try CreatorEngineDocument.parseCore(source, engine: engine, media: try mediaName.map(CreatorMediaDefaults.binding))
            document.metadata.title = title; document.metadata.masterID = id; document.parameters = parameters
            return try document.html()
        }
    }
    private struct Catalog: Codable { let version: Int; let masters: [Master] }
    static func all() throws -> [Master] {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "CreatorMasters") else { throw CreatorPersistence.Failure.invalidRecord }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.version == 2, catalog.masters.count == 15, Set(catalog.masters.map(\.id)).count == 15 else { throw CreatorPersistence.Failure.invalidRecord }
        for master in catalog.masters {
            guard master.engine.available, master.id.range(of: #"^[a-z]{1,24}$"#, options: .regularExpression) != nil,
                  master.file == master.id + (master.engine == .htmlCanvas ? ".html" : ".txt") else { throw CreatorPersistence.Failure.invalidRecord }
            try master.parameters.validate()
        }
        return catalog.masters
    }
    static func poster(_ id: String) throws -> Data {
        guard try all().contains(where: { $0.id == id }), let url = Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "CreatorMasters") else { throw CreatorPersistence.Failure.invalidRecord }
        let data = try Data(contentsOf: url)
        try CreatorBundleManifest.validatePoster(data)
        return data
    }
    static func closest(prompt: String, engine: CreatorEngine, masters: [Master]) -> Master? {
        let candidates = masters.filter { $0.engine == engine }
        return candidates.enumerated().max { lhs, rhs in
            let a = lhs.element.keywords.filter { prompt.localizedCaseInsensitiveContains($0) }.count
            let b = rhs.element.keywords.filter { prompt.localizedCaseInsensitiveContains($0) }.count
            return a == b ? lhs.offset > rhs.offset : a < b
        }?.element
    }
}
