import XCTest
@testable import WallpaperMachine

final class CreatorTemplateCatalogTests: XCTestCase {
    func testCatalogRejectsMissingUnknownWrongTypeAndOutOfRangeValues() throws {
        for definition in CreatorTemplateCatalog.all {
            try definition.validate(definition.defaults)
            var extra = definition.defaults
            extra["code"] = .choice("while(true){}")
            XCTAssertThrowsError(try definition.validate(extra))
            for parameter in definition.parameters {
                var missing = definition.defaults
                missing.removeValue(forKey: parameter.id)
                XCTAssertThrowsError(try definition.validate(missing))
                var invalid: [CreatorTemplateCatalog.Value] = []
                var valid: [CreatorTemplateCatalog.Value] = []
                switch parameter.domain {
                case .number(let range, _, let integer):
                    valid = [.number(range.lowerBound), .number(range.upperBound)]
                    invalid = [.number(range.lowerBound-1), .number(range.upperBound+1), .number(.nan),
                               .number(.infinity), .number(-.infinity), .bool(true), .choice("1")]
                    if integer { invalid.append(.number(range.lowerBound+0.5)) }
                case .bool:
                    valid = [.bool(false), .bool(true)]
                    invalid = [.number(0), .number(1), .choice("true")]
                case .choice(let choices):
                    valid = choices.map { .choice($0.value) }
                    invalid = [.choice("unknown"), .choice("</script>"), .number(1), .bool(false)]
                }
                for value in valid {
                    var values = definition.defaults; values[parameter.id] = value
                    XCTAssertNoThrow(try definition.validate(values), "\(definition.id).\(parameter.id)")
                }
                for value in invalid {
                    var values = definition.defaults; values[parameter.id] = value
                    XCTAssertThrowsError(try definition.validate(values), "\(definition.id).\(parameter.id)")
                }
            }
        }
    }

    func testJSONValuesKeepBooleanNumberAndEnumTypesDistinct() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(CreatorTemplateCatalog.Value.self, from: Data("true".utf8)), .bool(true))
        XCTAssertEqual(try decoder.decode(CreatorTemplateCatalog.Value.self, from: Data("1".utf8)), .number(1))
        XCTAssertEqual(try decoder.decode(CreatorTemplateCatalog.Value.self, from: Data(#""1""#.utf8)), .choice("1"))
        for invalid in ["null", "[]", "{}"] {
            XCTAssertThrowsError(try decoder.decode(CreatorTemplateCatalog.Value.self, from: Data(invalid.utf8)))
        }
    }

    func testCombinedStarParametersShareOneTotalBudget() throws {
        let definition = try CreatorTemplateCatalog.definition("stars-v2")
        for density in stride(from: 0.0, through: 1, by: 0.1) {
            for trail in stride(from: 0.0, through: 1, by: 0.1) {
                var previous: CreatorTemplateCatalog.Allocation?
                for layers in 1...4 {
                    var values = definition.defaults
                    values["starDensity"] = .number(density)
                    values["trailLength"] = .number(trail)
                    values["parallaxLayers"] = .number(Double(layers))
                    values["meteorRate"] = .number(6)
                    let allocation = try definition.allocation(for: values)
                    XCTAssertLessThanOrEqual(allocation.particles, definition.budget.maxParticles)
                    XCTAssertLessThanOrEqual(allocation.trailSegments, definition.budget.maxTrailSegments)
                    if let previous { XCTAssertEqual(previous, allocation, "Layers must not multiply work") }
                    previous = allocation
                }
            }
        }
    }

    func testPresetsProduceStrictReproducibleThreeFileBundlesAndControls() throws {
        for definition in CreatorTemplateCatalog.all {
            for preset in definition.presets {
                let spec = try definition.specification(parameters: preset.parameters)
                let files = try CreatorTemplate.files(for: spec)
                XCTAssertEqual(Set(files.keys), ["index.html", "project.json", "creator.json"])
                let decoded = try JSONDecoder().decode(CreatorTemplate.Specification.self, from: files["creator.json"]!)
                XCTAssertEqual(try CreatorTemplate.files(for: decoded), files)
                let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: files["project.json"]!) as? [String: Any])
                let general = try XCTUnwrap(manifest["general"] as? [String: Any])
                let properties = try XCTUnwrap(general["properties"] as? [String: [String: Any]])
                XCTAssertEqual(Set(properties.keys), Set(preset.parameters.keys))
                for parameter in definition.parameters {
                    let property = try XCTUnwrap(properties[parameter.id])
                    let data = try JSONSerialization.data(withJSONObject: property["value"]!, options: [.fragmentsAllowed])
                    XCTAssertEqual(try JSONDecoder().decode(CreatorTemplateCatalog.Value.self, from: data), preset.parameters[parameter.id])
                    XCTAssertEqual(PropertyLabels.engineTokenLabel(try XCTUnwrap(property["text"] as? String)), parameter.label)
                }
            }
        }
    }

    func testLegacyS0BundlesKeepTheirOriginalBytes() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let original: [CreatorTemplate.Kind: String] = [
            .gradient: "0942c4547f10dc215431012d0236e9ca2524d502049351835199b0de9673bf44",
            .stars: "343bfa8085915ff4e430da4bce22bfd419e44566c147f83f3ca68348a7a0c10e",
            .clock: "63ebb34cbfa8b717f1f70f23cb5c054397f6e31d8fa428576113742804af829a",
        ]
        for kind in CreatorTemplate.Kind.allCases {
            let files = try CreatorTemplate.files(for: .init(projectID: id, kind: kind))
            XCTAssertEqual(CreatorTemplate.digest(files), original[kind], "Persisted S0 bundles must still validate")
        }
    }

    func testLegacyV2BytesAndNewRendererVersionBoundary() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let digests = ["gradient-v2": "272ba8225a84468e15d08b7a8b0f34221bcad20bf0c4ee4191adc774a89bdb9b",
                       "stars-v2": "11e992410ed7f925919fa89d601b9940864c0f6090bba964d119bc82ec599aaa",
                       "clock-v2": "3a80ebb27bbc9cd1a86b2c165e94e4571973a5c344990990fd885531b245b98c"]
        for definition in CreatorTemplateCatalog.all {
            var spec = try definition.specification(projectID: id)
            XCTAssertEqual(spec.rendererRevision, 3)
            XCTAssertEqual(CreatorBundleManifest.templateIdentity(spec).revision, 3)
            let modern = try CreatorTemplate.files(for: spec)
            spec.rendererRevision = nil
            XCTAssertEqual(CreatorTemplate.digest(try CreatorTemplate.files(for: spec)), digests[definition.id])
            XCTAssertNotEqual(CreatorTemplate.digest(modern), digests[definition.id])
            XCTAssertEqual(CreatorBundleManifest.templateIdentity(spec).revision, 2)
            for invalid in [0, 1, 2, 4, Int.max] {
                spec.rendererRevision = invalid
                XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
            }
        }
    }

    func testUnknownRevisionsMixedLegacyFieldsAndKindMismatchFailClosed() throws {
        var spec = try CreatorTemplateCatalog.definition("stars-v2").specification()
        spec.templateID = "stars-v3"
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
        spec.templateID = "stars-v2"; spec.kind = .clock
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
        spec.kind = .stars; spec.hue = 20
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
        spec.hue = 220; spec.parameters = nil
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
        spec = try CreatorTemplateCatalog.definition("stars-v2").specification()
        spec.templateID = nil
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec))
        spec = try CreatorTemplateCatalog.definition("stars-v2").specification()
        spec.version = 2
        XCTAssertThrowsError(try CreatorTemplate.files(for: spec), "Bundle v2 belongs to S1.1, not this step")
    }

    func testTamperedEnhancedBundlesCannotBypassByteReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreatorDraftStore(root: root)
        let directory = try await store.create(CreatorTemplateCatalog.definition("gradient-v2").specification())
        let original = try await store.snapshot(directory)
        let metadata = directory.appendingPathComponent("creator.json")
        let text = String(decoding: original.files["creator.json"]!, as: UTF8.self)
        for changed in [text.replacingOccurrences(of: "{", with: "{\"unexpected\":0,", range: text.startIndex..<text.index(after: text.startIndex)),
                        "{\"version\":1," + text.dropFirst()] {
            try Data(changed.utf8).write(to: metadata)
            do { _ = try await store.snapshot(directory); XCTFail("Accepted noncanonical metadata") } catch {}
        }
        try original.files["creator.json"]!.write(to: metadata)
        try Data("<script>while(true){}</script>".utf8).write(to: directory.appendingPathComponent("index.html"))
        do { _ = try await CreatorPreview.make(directory: directory, store: store); XCTFail("Accepted arbitrary source") } catch {}
    }

    func testEnhancedImportAndInterruptedReplacementRecoverLegacyBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let publication = root.appendingPathComponent("publication")
        let publisher = CreatorPublisher(root: publication, library: library)
        let id = UUID()
        let oldStore = CreatorDraftStore(root: root.appendingPathComponent("old"))
        let original = try await oldStore.create(.init(projectID: id, kind: .gradient))
        let before = try await oldStore.snapshot(original)
        let installed = try await publisher.publish(original, expectedDigest: before.digest) { _ in }
        for definition in CreatorTemplateCatalog.all {
            let store = CreatorDraftStore(root: root.appendingPathComponent(definition.id))
            let candidate = try await store.create(definition.specification(projectID: id))
            let snapshot = try await store.snapshot(candidate)
            let ticket = try await publisher.prepare(candidate, expectedDigest: snapshot.digest)
            _ = try await publisher.install(ticket)
            XCTAssertEqual(try CreatorDraftStore.read(installed).digest, snapshot.digest)
            try await CreatorPublisher(root: publication, library: library).recover()
            XCTAssertEqual(try CreatorDraftStore.read(installed).files, before.files)
        }
        let finalStore = CreatorDraftStore(root: root.appendingPathComponent("final"))
        let candidate = try await finalStore.create(CreatorTemplateCatalog.definition("clock-v2").specification(projectID: id))
        let snapshot = try await finalStore.snapshot(candidate)
        _ = try await publisher.publish(candidate, expectedDigest: snapshot.digest) { destination in
            XCTAssertEqual(try CreatorDraftStore.read(destination).digest, snapshot.digest)
        }
        try await CreatorPublisher(root: publication, library: library).recover()
        XCTAssertEqual(try CreatorDraftStore.read(installed).digest, snapshot.digest)
    }

    @MainActor
    func testAllCatalogLabelsResolveInEveryShippedLanguage() throws {
        var keys = Set<String>()
        for definition in CreatorTemplateCatalog.all {
            keys.insert(definition.label)
            keys.formUnion(definition.presets.map(\.label))
            for parameter in definition.parameters {
                keys.insert(parameter.label)
                if case .choice(let choices) = parameter.domain { keys.formUnion(choices.map(\.label)) }
            }
        }
        // English source keys are the intentional fallback for existing catalog entries.
        for language in AppLanguage.supported where language.tag != "en" {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.tag, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "<missing>", table: nil), "<missing>", "\(language.tag): \(key)")
            }
        }
    }
}
