# Site branding assets

- `frontend/favicon.svg`: hand-authored yellow car, road, and pine-tree logo.
  `icon.svg` uses the same art for Godot's application/export icon.
- `frontend/favicon.ico`: 16, 32, and 48 pixel PNG frames rendered from that SVG
  with Godot, packaged in an ICO container.
- `frontend/apple-touch-icon.png`: 180 pixel rendering of the same SVG.
- `frontend/media/social-preview.png`: 1200 × 630 social card, made with the
  built-in image-generation tool using `frontend/media/two-seats.png` as its source.
  This is composed marketing artwork rather than an unmodified screenshot.
  The generated result was resized for Open Graph with macOS `sips`.

The original gameplay screenshots remain unchanged. Social metadata and the
trailer player live in `frontend/shell.html`; `tools/export_web.sh` packages the
assets. See [deployment.md](../deployment.md#browser-frontend) for hosting details.

## Share-card generation prompt

Use case: compositing. Create a polished social link preview image for the browser co-op game BLIND DRIVER, landscape exactly 1200 by 630 pixels (1.905:1). Input image is the gameplay source: use its split screen as the main imagery, preserving the idea and low-poly forest game appearance: left half heavily blurred driver windshield, right half clear navigator view of a forest road and yellow hood. Crop away all editor chrome, black outer borders, existing UI text, map and lower HUD. Do not invent a different game scene. Design an elegant dark forest-green header band in the top 28 percent, with large bold warm cream sans-serif title 'BLIND DRIVER' and below it smaller exact text 'One drives. One sees the way.' Below, place equal side-by-side cropped gameplay views. Add compact clean cream labels 'YOU DRIVE' at the upper left of the blurred half and 'YOU GUIDE' at the upper left of the clear half. Use a narrow golden yellow central divider. A slim dark forest-green footer contains exact text 'A chaotic co-op getaway. Play in your browser.' High legibility at small social-card size, restrained warm yellow accents and cream type, generous consistent padding, no decorative icons, no extra wording, no logos of other companies. This is a finished flat image, not a mockup.
