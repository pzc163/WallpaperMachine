# Offline Three.js runtime

Pinned upstream Three.js 0.180.0 (r180), MIT. `manifest.json` records npm archive
integrity, the build tool and reviewed bundle hash. `entry.js` selects the WebGL
core and RoomEnvironment, EffectComposer, RenderPass, UnrealBloomPass and OutputPass.
The generated classic script is copied into the app as a resource. It has no CDN,
source map, external image or font dependency; the host uses procedural environment
lighting. CSP and the native exact-URL scheme handler still prohibit network access.

Check offline with `python3 scripts/bundle_creator_libraries.py`. Explicitly rebuild
on Apple Silicon macOS with `python3 scripts/bundle_creator_libraries.py --rebuild`.
The latter downloads integrity-pinned npm archives into a disposable directory,
executes no package lifecycle scripts and requires the result to match the reviewed
hash. A library upgrade needs a new runtime version and new verification evidence;
do not overwrite this version's resources or weaken digest checks.
