import Foundation

/// A narrow native proof: only bounded parameter values may change, never author code or libraries.
enum CreatorParameterUpdate {
    static func validate(before: CreatorDraftStore.Snapshot, after: CreatorDraftStore.Snapshot,
                         values: [String: CreatorTemplateCatalog.Value]) throws {
        guard before.specification.projectID == after.specification.projectID,
              before.specification.kind == after.specification.kind,
              before.specification.runtimePolicy == after.specification.runtimePolicy,
              let previous = before.files["index.html"], let next = after.files["index.html"]
        else { throw CreatorRuntimeFailure.staleInput }
        if before.specification.kind == .code {
            let html = String(decoding: previous, as: UTF8.self)
            guard let schema = try CreatorParameterSchema.read(html),
                  Data(try schema.replacing(in: html, with: values).utf8) == next
            else { throw CreatorRuntimeFailure.staleInput }
        } else {
            guard let id = before.specification.templateID else { throw CreatorRuntimeFailure.staleInput }
            try CreatorTemplateCatalog.definition(id).validate(values)
            var expected = before.specification; expected.parameters = values; expected.rendererRevision = 3
            guard expected == after.specification else { throw CreatorRuntimeFailure.staleInput }
        }
    }
}
