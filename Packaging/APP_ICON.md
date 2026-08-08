# ChirpCue app icon

The shipping icon is `AppIcon.icns`; `AppIcon-1024.png` is the 1024-pixel source.

It was created with the built-in image-generation tool, resized to 1024 by 1024 pixels, given transparent outer corners with the bundled local background-removal helper, and packed with `Scripts/build-app-icon.sh`.

Final generation prompt:

```text
Create an original, joyful macOS application icon for ChirpCue, an invisible conversation sidekick that quietly suggests what to say in meetings. Center a tiny abstract cricket-and-firefly helper made from luminous glass, with two simple antennae and subtle speech-bubble-shaped wings. Use polished Apple-like Liquid Glass, a deep midnight-teal translucent tile, a chartreuse and emerald body, cyan highlights, and one small warm-gold glow. Keep the silhouette clear at 16 pixels, with generous padding, restrained depth, and no text. The mascot must be wholly original and non-human. Avoid realistic insect anatomy, existing-character resemblance, human clothing, hats, umbrellas, canes, tailcoats, gloves, busy scenery, or watermarks.
```

The helper removed only the flat black exterior around the rounded tile, using a soft matte, despill, a transparent threshold of 6, and an opaque threshold of 28. Final validation proves 1024 by 1024 pixels, an alpha channel, 160,550 fully transparent pixels, and a crisp 64-pixel preview. Rebuild the shipping icon with `./Scripts/build-app-icon.sh`.
