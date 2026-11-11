import CryptoKit
import Foundation

/// Byte-reproducible trusted bundles; legacy S0 and versioned catalog templates share the host.
enum CreatorTemplate {
    static let idPrefix = "creator-s0-"
    static let metadataFile = "creator.json"
    static let policyVersion = 1

    enum Kind: String, Codable, CaseIterable, Sendable { case gradient, stars, clock, code
        static let templates: [Kind] = [.gradient, .stars, .clock]
    }

    struct Specification: Codable, Equatable, Sendable {
        var version = 1
        var projectID: UUID
        var kind: Kind
        var hue: Double = 220
        var speed: Double = 0.5
        var templateID: String? = nil
        var parameters: [String: CreatorTemplateCatalog.Value]? = nil
        var rendererRevision: Int? = nil
        var codeDigest: String? = nil
        var libraryDigest: String? = nil
        var runtimePolicy: String { kind == .code ? "generatedOfflineV1" : "trustedTemplateV1" }
        var creationMode: CreatorCreationMode { kind == .code ? .code : .template }

        var wallpaperID: String { CreatorTemplate.idPrefix + projectID.uuidString.lowercased() }
    }

    enum Failure: Error { case invalidSpecification, invalidBundle, changedContent, invalidPath, busy, invalidTransaction }

    static func files(for spec: Specification) throws -> [String: Data] {
        guard spec.kind != .code, spec.codeDigest == nil, spec.libraryDigest == nil, spec.version == policyVersion, spec.hue.isFinite, (0...360).contains(spec.hue),
              spec.speed.isFinite, (0...2).contains(spec.speed) else { throw Failure.invalidSpecification }
        if spec.templateID != nil || spec.parameters != nil { return try CreatorTemplateRenderer.files(for: spec) }
        guard spec.rendererRevision == nil else { throw Failure.invalidSpecification }
        // Freeze this legacy generator: existing S0 bundles must reconstruct to the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let script = """
        (() => {
          const canvas = document.getElementById('canvas'), ctx = canvas.getContext('2d');
          const clock = document.getElementById('clock');
          let hue = \(spec.hue), speed = \(spec.speed), paused = false, raf = 0, previous = 0, time = 0;
          const kind = '\(spec.kind.rawValue)';
          function resize() {
            const ratio = Math.min(window.devicePixelRatio || 1, 2);
            canvas.width = Math.max(1, Math.min(3840, Math.round(innerWidth * ratio)));
            canvas.height = Math.max(1, Math.min(2160, Math.round(innerHeight * ratio)));
            draw();
          }
          function draw() {
            const w = canvas.width, h = canvas.height;
            const gradient = ctx.createLinearGradient(0, 0, w, h);
            gradient.addColorStop(0, `hsl(${hue},65%,8%)`);
            gradient.addColorStop(1, `hsl(${(hue + 45) % 360},55%,${18 + Math.sin(time * speed) * 4}%)`);
            ctx.fillStyle = gradient; ctx.fillRect(0, 0, w, h);
            if (kind === 'stars') {
              ctx.fillStyle = '#fff';
              for (let i = 0; i < 96; i++) {
                const x = ((i * 0.61803398875 + time * speed * 0.003) % 1) * w;
                const y = ((i * 0.41421356237) % 1) * h;
                ctx.globalAlpha = 0.35 + (Math.sin(time + i) + 1) * 0.25;
                ctx.beginPath(); ctx.arc(x, y, 1 + i % 3, 0, Math.PI * 2); ctx.fill();
              }
              ctx.globalAlpha = 1;
            }
            clock.textContent = kind === 'clock' ? new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}) : '';
          }
          function frame(now) {
            raf = 0;
            if (paused) return;
            time += previous ? Math.min((now - previous) / 1000, 0.1) : 0; previous = now;
            draw(); raf = requestAnimationFrame(frame);
          }
          window.wallpaperPropertyListener = {
            applyUserProperties(p) {
              if (p.hue && Number.isFinite(Number(p.hue.value))) hue = Math.max(0, Math.min(360, Number(p.hue.value)));
              if (p.speed && Number.isFinite(Number(p.speed.value))) speed = Math.max(0, Math.min(2, Number(p.speed.value)));
              draw();
            },
            setPaused(value) {
              paused = !!value;
              if (raf) cancelAnimationFrame(raf);
              raf = 0; previous = 0;
              if (!paused) raf = requestAnimationFrame(frame);
            }
          };
          window.addEventListener('resize', resize);
          window.addEventListener('pagehide', () => { paused = true; if (raf) cancelAnimationFrame(raf); });
          resize(); raf = requestAnimationFrame(frame);
        })();
        """
        let style = "html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#081020}canvas{width:100%;height:100%;display:block}#clock{position:fixed;inset:0;display:grid;place-items:center;color:white;font:8vw system-ui;pointer-events:none}"
        let policy = "default-src 'none'; script-src 'sha256-\(base64Hash(script))'; style-src 'sha256-\(base64Hash(style))'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)"><meta name="viewport" content="width=device-width,initial-scale=1"><style>\(style)</style></head><body><canvas id="canvas"></canvas><div id="clock"></div><script>\(script)</script></body></html>
        """
        let manifest: [String: Any] = [
            "title": "S0 · \(spec.kind.rawValue)", "type": "web", "file": "index.html",
            "general": ["properties": [
                "hue": ["type": "slider", "text": "Hue", "value": spec.hue, "min": 0, "max": 360, "order": 0],
                "speed": ["type": "slider", "text": "Speed", "value": spec.speed, "min": 0, "max": 2, "order": 1],
            ]],
        ]
        return [
            "index.html": Data(html.utf8), metadataFile: try encoder.encode(spec),
            "project.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]),
        ]
    }

    static func digest(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for key in files.keys.sorted() {
            let data = files[key]!
            hash.update(data: Data("\(key.utf8.count):\(key):\(data.count):".utf8))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func base64Hash(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }
}
