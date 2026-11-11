import CryptoKit
import Foundation

/// Frozen revision 2 bytes for persisted bundles. Never change this generator.
enum CreatorTemplateLegacyRenderer {
    static func files(for spec: CreatorTemplate.Specification) throws -> [String: Data] {
        guard let id = spec.templateID, let values = spec.parameters, spec.hue == 220, spec.speed == 0.5 else {
            throw CreatorTemplate.Failure.invalidSpecification
        }
        let definition = try CreatorTemplateCatalog.definition(id)
        guard definition.kind == spec.kind else { throw CreatorTemplate.Failure.invalidSpecification }
        try definition.validate(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rules = Dictionary(uniqueKeysWithValues: definition.parameters.map { ($0.id, $0.domain.runtimeRule) })
        let ruleData = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        let script = """
        (() => {
          'use strict';
          const kind = '\(definition.kind.rawValue)';
          const p = \(String(decoding: try encoder.encode(values), as: UTF8.self));
          const rules = \(String(decoding: ruleData, as: UTF8.self));
          const budget = \(String(decoding: try encoder.encode(definition.budget), as: UTF8.self));
        \(kernel)
        })();
        """
        let style = "html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#081020}canvas{width:100%;height:100%;display:block}"
        func hash(_ string: String) -> String { Data(SHA256.hash(data: Data(string.utf8))).base64EncodedString() }
        let policy = "default-src 'none'; script-src 'sha256-\(hash(script))'; style-src 'sha256-\(hash(style))'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)"><meta name="viewport" content="width=device-width,initial-scale=1"><style>\(style)</style></head><body><canvas id="canvas"></canvas><script>\(script)</script></body></html>
        """
        let manifest: [String: Any] = [
            "title": definition.label, "type": "web", "file": "index.html",
            "general": ["properties": try definition.properties(for: values)],
        ]
        return ["index.html": Data(html.utf8), CreatorTemplate.metadataFile: try encoder.encode(spec),
                "project.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])]
    }

    private static let kernel = #"""
      const canvas = document.getElementById('canvas'), ctx = canvas.getContext('2d');
      const tau = Math.PI * 2;
      let seed = budget.seed;
      const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
      const stars = Array.from({length: budget.maxParticles}, () => ({x:random(),y:random(),r:random(),phase:random()*tau}));
      const grain = Array.from({length: budget.maxGrain}, () => ({x:random(),y:random(),a:random()}));
      let paused = false, ended = false, raf = 0, redrawTimer = 0, lastPaint = null, previous = null, time = 0, dirty = true;
      let fps = budget.maxFPS, nextWidth = 1, nextHeight = 1;
      const mod = (value, divisor) => ((value % divisor) + divisor) % divisor;
      const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
      const color = (hue, light, alpha = 1) => `hsla(${hue},65%,${light}%,${alpha})`;

      function schedule() {
        if (!ended && !raf && !paused) raf = requestAnimationFrame(frame);
      }
      // A detached WebKit view may not get animation frames. Paint on demand,
      // coalescing edits/resizes under the same ceiling; never animate with a timer.
      function flushDirty() {
        if (ended || !dirty) return;
        const now = performance.now();
        if (paint(now)) return;
        if (!redrawTimer) redrawTimer = setTimeout(() => { redrawTimer = 0; flushDirty(); }, Math.max(1,1000/fps-(now-lastPaint)));
      }
      function invalidate() { dirty = true; flushDirty(); schedule(); }
      function resize() {
        const w = clamp(Number.isFinite(innerWidth) ? innerWidth : 1, 1, 65536);
        const h = clamp(Number.isFinite(innerHeight) ? innerHeight : 1, 1, 65536);
        const dpr = clamp(Number.isFinite(devicePixelRatio) ? devicePixelRatio : 1, 0.1, budget.maxDeviceScale);
        const scale = Math.min(dpr, budget.maxDimension/w, budget.maxDimension/h, Math.sqrt(budget.maxPixels/(w*h)));
        nextWidth = Math.max(1, Math.floor(w*scale)); nextHeight = Math.max(1, Math.floor(h*scale));
        invalidate();
      }
      function background(w, h) {
        const angle = (kind === 'gradient' ? p.angle : 35) * Math.PI / 180;
        const radius = Math.abs(Math.cos(angle))*w/2 + Math.abs(Math.sin(angle))*h/2;
        const dx = Math.cos(angle)*radius, dy = Math.sin(angle)*radius;
        const contrast = kind === 'gradient' ? p.contrast : 0.7;
        const speed = kind === 'clock' ? p.backgroundMotion : p.motionSpeed;
        const pulse = kind === 'gradient' ? Math.sin(time*p.breathingHz*tau)*6 : 0;
        const g = ctx.createLinearGradient(w/2-dx,h/2-dy,w/2+dx,h/2+dy);
        g.addColorStop(0,color(p.primaryHue,18-contrast*12+pulse));
        g.addColorStop(1,color(p.secondaryHue,28+contrast*14+pulse));
        ctx.fillStyle = g; ctx.fillRect(0,0,w,h);
        const strength = kind === 'gradient' ? p.waveStrength : 0.35;
        const scale = kind === 'gradient' ? p.waveScale : 1.4;
        for (let i=0; i<budget.gradientBands; i++) {
          const y = h*(i+0.5)/budget.gradientBands;
          const offset = Math.sin(i*scale+time*speed)*h*strength*0.3;
          ctx.fillStyle = color(i%2 ? p.primaryHue : p.secondaryHue,65,0.035+strength*0.1);
          ctx.beginPath(); ctx.moveTo(0,y);
          ctx.bezierCurveTo(w*0.3,y+offset,w*0.7,y-offset,w,y+Math.cos(time*speed+i)*h*strength*0.2);
          ctx.lineTo(w,y+h/budget.gradientBands*0.6); ctx.bezierCurveTo(w*0.7,y-offset,w*0.3,y+offset,0,y+h/budget.gradientBands*0.6);
          ctx.closePath(); ctx.fill();
        }
        if (kind === 'gradient') {
          for (const dot of grain) {
            ctx.fillStyle = `rgba(255,255,255,${dot.a*p.grainAmount*0.5})`;
            const size = 1+p.grainAmount*2; ctx.fillRect(dot.x*w,dot.y*h,size,size);
          }
          const v = ctx.createRadialGradient(w/2,h/2,Math.min(w,h)*0.1,w/2,h/2,Math.hypot(w,h)/2);
          v.addColorStop(0,'transparent'); v.addColorStop(1,`rgba(0,0,0,${p.vignette*0.9})`);
          ctx.fillStyle = v; ctx.fillRect(0,0,w,h);
        }
      }
      function starfield(w,h) {
        const count = Math.floor(p.starDensity*budget.maxParticles);
        const segments = Math.min(Math.floor(p.trailLength*budget.maxTrailSegmentsPerParticle),Math.floor(budget.maxTrailSegments/Math.max(1,count)));
        const unit = Math.max(0.5,Math.min(w,h)/540);
        for (let i=0; i<count; i++) {
          const star = stars[i], depth = (i%p.parallaxLayers+1)/p.parallaxLayers;
          const x = mod(star.x+time*p.motionSpeed*0.025*depth,1)*w, y = star.y*h;
          const radius = (0.65+star.r*p.starSizeSpread*3)*(0.6+depth*0.4)*unit;
          const alpha = 0.55+Math.sin(time*p.twinkleHz*tau+star.phase)*0.35;
          ctx.fillStyle = color(i%2 ? p.primaryHue : p.secondaryHue,90,alpha);
          ctx.beginPath(); ctx.arc(x,y,radius,0,tau); ctx.fill();
          const length = p.trailLength*Math.min(w,h)*0.05*depth*(0.25+p.motionSpeed);
          ctx.lineWidth = Math.max(0.5,radius*0.65);
          for (let j=0; j<segments; j++) {
            ctx.strokeStyle = color(p.secondaryHue,85,alpha*(1-j/segments)*0.45);
            ctx.beginPath(); ctx.moveTo(x-length*j/segments,y); ctx.lineTo(x-length*(j+1)/segments,y); ctx.stroke();
          }
        }
        if (p.meteorRate > 0) {
          const period = 60/p.meteorRate;
          for (let i=0; i<budget.maxMeteors; i++) {
            // Slots divide the requested rate; layers/density never multiply it.
            const cycle = period*budget.maxMeteors, shifted = time-i*period;
            if (shifted < 0) continue;
            const age = mod(shifted,cycle);
            if (age >= 1.8) continue;
            const star = stars[mod(Math.floor(shifted/cycle)*7+i*37,stars.length)];
            const x = (star.x*0.7+age*0.3)*w, y = (star.y*0.45+age*0.18)*h;
            ctx.strokeStyle = color(p.secondaryHue,95,Math.sin(age/1.8*Math.PI)); ctx.lineWidth = 2*unit;
            ctx.beginPath(); ctx.moveTo(x,y); ctx.lineTo(x-w*0.12,y-h*0.08); ctx.stroke();
          }
        }
      }
      const anchors = {topLeft:[0,0],topCenter:[0.5,0],topRight:[1,0],middleLeft:[0,0.5],center:[0.5,0.5],middleRight:[1,0.5],bottomLeft:[0,1],bottomCenter:[0.5,1],bottomRight:[1,1]};
      const fonts = {system:'system-ui',serif:'Georgia,serif',monospace:'Menlo,monospace'};
      function clock(w,h) {
        const now = new Date(), isClock = kind === 'clock';
        const size = Math.min(w,h)*(isClock ? 0.105 : 0.075)*p.clockScale;
        const [ax,ay] = anchors[p.clockAnchor], margin = Math.min(w,h)*0.07;
        const date = isClock && p.showDate;
        const height = size*(date ? 1.8 : 1);
        const x = margin+(w-2*margin)*ax, y = margin+(h-2*margin-height)*ay;
        ctx.save(); ctx.textAlign = ax===0 ? 'left' : ax===1 ? 'right' : 'center'; ctx.textBaseline = 'top';
        ctx.font = `500 ${size}px ${isClock ? fonts[p.font] : fonts.system}`;
        ctx.fillStyle = color(p.primaryHue,95);
        ctx.shadowColor = color(p.secondaryHue,75); ctx.shadowBlur = isClock ? p.glow*size*0.5 : 0;
        const text = now.toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit',second:isClock && p.showSeconds ? '2-digit' : undefined,hour12:isClock && p.hourFormat==='12h'});
        ctx.fillText(text,x,y,w-2*margin);
        if (date) { ctx.font = `400 ${size*0.36}px ${fonts[p.font]}`; ctx.fillText(now.toLocaleDateString(),x,y+size*1.3,w-2*margin); }
        ctx.restore();
      }
      function draw() {
        // Resize only when a replacement frame is ready, retaining the previous
        // pixels while throttled instead of clearing the canvas between frames.
        if (canvas.width !== nextWidth) canvas.width = nextWidth;
        if (canvas.height !== nextHeight) canvas.height = nextHeight;
        const w = canvas.width, h = canvas.height;
        background(w,h);
        if (kind === 'stars') starfield(w,h);
        if (kind === 'clock' || (kind === 'stars' && p.clockVisible)) clock(w,h);
      }
      function paint(now) {
        if (lastPaint !== null && now-lastPaint+0.001 < 1000/fps) return false;
        if (!paused && previous !== null) time += clamp((now-previous)/1000,0,0.1);
        previous = paused ? null : now;
        draw(); dirty = false; lastPaint = now;
        if (redrawTimer) clearTimeout(redrawTimer); redrawTimer = 0;
        return true;
      }
      function frame(now) {
        raf = 0;
        if (ended) return;
        if (dirty || !paused) paint(now);
        schedule();
      }
      window.wallpaperPropertyListener = {
        applyUserProperties(properties) {
          let changed = false;
          for (const [key,rule] of Object.entries(rules)) {
            const value = properties[key]?.value;
            if (typeof value !== rule.type) continue;
            if (rule.type === 'number' && (!Number.isFinite(value) || value<rule.min || value>rule.max || (rule.integer && !Number.isInteger(value)))) continue;
            if (rule.choices && !rule.choices.includes(value)) continue;
            if (p[key] !== value) { p[key] = value; changed = true; }
          }
          if (changed) invalidate();
        },
        applyGeneralProperties(properties) {
          if (typeof properties.fps === 'number' && Number.isFinite(properties.fps) && properties.fps >= 0)
            fps = properties.fps === 0 ? budget.maxFPS : clamp(properties.fps,1,budget.maxFPS);
        },
        setPaused(value) {
          paused = !!value; previous = null;
          if (raf) cancelAnimationFrame(raf); raf = 0; schedule();
        }
      };
      addEventListener('resize',resize);
      addEventListener('pagehide',() => { ended = true; if (raf) cancelAnimationFrame(raf); if (redrawTimer) clearTimeout(redrawTimer); raf = 0; redrawTimer = 0; });
      resize();
    """#
}
