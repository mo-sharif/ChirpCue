# PaceNote app icon

The shipping icon is `AppIcon.icns`; `AppIcon-1024.png` is the transparent-corner source.

It was created with the built-in image-generation tool, then locally chroma-keyed, edge-contracted by one pixel, resized, and packed with `iconutil`.

Final generation prompt:

```text
Use case: logo-brand
Asset type: final 1024x1024 macOS app icon for PaceNote, a private real-time conversation coach
Primary request: an original abstract mark that combines a calm speech bubble silhouette with two flowing response pulses, one short immediate pulse and one deeper trailing pulse
Style/medium: polished native macOS app icon, minimal geometric forms, crisp at small sizes, softly dimensional rather than photorealistic
Composition/framing: centered strong silhouette inside a rounded-square tile with generous optical padding; perfectly front-facing and symmetric enough to read at 16px
Color palette: deep midnight indigo base, luminous cobalt and cyan primary pulse, one restrained warm amber accent for the second response
Lighting/mood: confident, private, calm, technically precise
Constraints: no text, no letters, no microphone, no human face, no ear, no robot, no code brackets, no Apple or third-party symbols, no watermark, no mockup scene, no extra border outside the rounded square; keep details large and simple for app-icon scaling
```

The follow-up edit changed only the pixels outside the rounded-square tile to a flat green chroma key. The local background-removal helper used a soft matte, despill, and one-pixel edge contraction. Final validation proved 1024 by 1024 pixels, an alpha channel, and fully transparent corner pixels.
