import CryptoKit
import Foundation

/// Revision 3 adds WebGL without changing the catalog or persisted revision 2 bytes.
enum CreatorTemplateRenderer {
    static func files(for spec: CreatorTemplate.Specification) throws -> [String: Data] {
        if spec.rendererRevision == nil { return try CreatorTemplateLegacyRenderer.files(for: spec) }
        guard spec.rendererRevision == 3, let id = spec.templateID, let values = spec.parameters,
              spec.hue == 220, spec.speed == 0.5 else { throw CreatorTemplate.Failure.invalidSpecification }
        let definition = try CreatorTemplateCatalog.definition(id)
        guard definition.kind == spec.kind else { throw CreatorTemplate.Failure.invalidSpecification }
        try definition.validate(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let rules = Dictionary(uniqueKeysWithValues: definition.parameters.map { ($0.id, $0.domain.runtimeRule) })
        let ruleData = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        let script = """
        (()=>{'use strict';
        const kind='\(spec.kind.rawValue)',p=\(try json(values)),budget=\(try json(definition.budget));
        const rules=\(String(decoding: ruleData, as: UTF8.self));
        const vertex=\(try json(CreatorTemplateShaders.vertex)),fragment=\(try json(CreatorTemplateShaders.fragment));
        \(CreatorTemplateWebGLKernel.source)
        })();
        """
        let style = "html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}canvas{position:absolute;inset:0;width:100%;height:100%;display:block}#hud{position:absolute;pointer-events:none;color:#f5f7ff;font-variant-numeric:tabular-nums;font-feature-settings:'tnum';line-height:1.14;letter-spacing:-.035em;white-space:nowrap;transform-origin:top left}#date{font-size:.25em;line-height:1.6;letter-spacing:.12em;opacity:.62;margin-top:.55em}"
        func hash(_ text: String) -> String { Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() }
        let policy = "default-src 'none'; script-src 'sha256-\(hash(script))'; style-src 'sha256-\(hash(style))'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)"><meta name="viewport" content="width=device-width,initial-scale=1"><style>\(style)</style></head><body><canvas id="canvas"></canvas><div id="hud"><div id="digits"></div><div id="date"></div></div><script>\(script)</script></body></html>
        """
        let manifest: [String: Any] = ["title": definition.label, "type": "web", "file": "index.html",
                                     "general": ["properties": try definition.properties(for: values)]]
        return ["index.html": Data(html.utf8), CreatorTemplate.metadataFile: try encoder.encode(spec),
                "project.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])]
    }
}
