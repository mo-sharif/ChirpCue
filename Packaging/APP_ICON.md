# PrismCue app icon

The shipping icon is `AppIcon.icns`; `AppIcon-1024.png` is the transparent-corner source.

It was created with the built-in image-generation tool, then locally chroma-keyed, edge-contracted by one pixel, resized, and packed with `Scripts/build-app-icon.sh`.

Final generation prompt:

```text
Create a production-quality macOS application icon for a personal real-time meeting coach named PrismCue. Logo-brand style, one centered symbolic mark, no text and no letters. Visual concept: a crisp translucent glass speech prism, shaped like a simplified faceted speech bubble, refracting one short bright cyan conversational cue and one deeper violet response beam. The prism should feel intelligent, calm, private, and fast, not like a robot or microphone. Use native Apple-like premium glass material, subtle spectral highlights, realistic refraction, restrained bloom, and a strong clean silhouette that remains recognizable at 16 px. Composition: centered, generous safe margin, symmetric visual balance, front three-quarter view, rounded-square macOS icon canvas. Background: intentional opaque deep midnight-indigo gradient with a soft radial halo. Palette: cyan and violet only with tiny neutral white highlights. High contrast, minimal detail, polished 3D render, 1024x1024 square. Avoid text, watermarks, faces, people, microphones, waveform squiggles, robots, third-party logos, or trademarked marks.
```

The follow-up edit changed only the pixels outside the rounded-square tile to a flat green chroma key. The local background-removal helper used a soft matte, despill, and one-pixel edge contraction. Final validation proved 1024 by 1024 pixels, an alpha channel, and fully transparent corner pixels. Rebuild the shipping icon with `./Scripts/build-app-icon.sh`.
