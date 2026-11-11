# Built-in media artwork

Three original AI-assisted backgrounds created for WallpaperMachine S5.2 with OpenAI image generation; no stock photographs or externally linked textures. They ship under the repository license. No user-uploaded media is included.

- **night**: 16:9 fine-art city photography, rain-soaked distant lights in midnight indigo and charcoal with cyan/amber accents; quiet upper-left space, no text, people, logos or baked glass droplets.
- **lake**: 16:9 painterly alpine lake at dawn, peach/lavender sky, layered pine forests and mountains around a 43% horizon, calm reflective lower half; no baked rays or ripple effects.
- **forest**: 16:9 nocturnal forest glade and stream, cool blue-green depth with warm moonlight behind trees on the right; no baked fireflies, strong light beams, characters or lettering.

Native CreatorMediaAnalysis normalizes these images into bounded JPEGs, derives 512px luminance PNGs and opt-in thumbnails, strips metadata, and writes content-addressed filenames. Each JSON descriptor and every media byte is pinned/verified by CreatorMediaDefaults. Gallery JPEGs are actual WKWebView snapshots of the corresponding animated master, not these background originals.
