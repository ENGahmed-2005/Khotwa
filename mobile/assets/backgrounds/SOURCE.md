# Khotwa photographic backgrounds

Created for this project on 2026-11-17 with the built-in image generator. These are generated decorative interiors, without real people, child records, identifying text, screens or medical material. The existing Khotwa logo is unchanged.

| Bundled asset | Dimensions | Bytes | SHA256 |
|---|---|---|---|
| learning-room.webp | 960×1440 | 56,132 | fae32cd182873550228547cce4cd8d10546166e4cc80043901c06f9f0fb43017 |
| learning-desk.webp | 1280×720 | 37,922 | 229ca74ca7c5b6535a871657fdf66a5e131f10a439f98537c8f05671642104ed |

Both assets are explicitly declared in pubspec.yaml, rendered locally, and usable offline. They add 94,054 bytes before packaging. Metadata was removed and size variants encoded with sharp0.35.5, WebP quality78/effort6. The original generated PNGs are preserved without edits in the local workspace under `.artifacts/artwork/2026-11-17/`; they are not bundled in the application. Artwork provenance and output checks are in that directory's assets.json. A failed generation attempt on Nov16 produced no assets; only the successful Nov17 images are used.

## Original prompts

**Learning room:** Use case: photorealistic-natural. Produce one sophisticated photographic background for Khotwa, a professional Arabic educational support app for learning specialists. Portrait 2:3 interior photograph of a calm inviting contemporary learning consultation room: warm ivory plaster wall, light oak furniture, soft sheer curtains and sunlight, small healthy sage-green plant at the side, restrained navy/amber books and a tidy pencil holder near the lower edge. Realistic materials, gentle optical depth of field, premium editorial interior photography, warm cream/navy/amber/sage palette. The center and upper central65% must be quiet softly defocused ivory wall and diffused daylight to allow readable interface cards later. Arrange modest educational room details toward the far edges and a little desk detail along the bottom quarter. Subtle, uncluttered and professional rather than childish or medical. No people, children, faces or portraits, screens, readable writing, letters, logos, numbers, medical equipment, app UI or watermark. Generate only the photographic image.

**Welcome desk:** Use case: photorealistic-natural. One premium wide editorial interior photograph for the welcome banner of Khotwa, an Arabic learning specialist app. Landscape16:9 composition: on the LEFT third a beautifully arranged light oak learning desk, open blank ivory notebook, two tasteful navy and muted amber books, a ceramic pencil holder, small green plant. The RIGHT two thirds is quiet softly defocused warm ivory wall with gentle daylight and little visual detail, leaving space for an Arabic heading added later. Warm natural sunlight, beautiful paper and wood materials, soft depth of field, modern calm consultation room. Palette navy17375E, amberE3A343, warm creamF8F5EF and sage. Objects should remain readable on the left even after cropping into a mobile banner. Professional, refined, not a school cartoon. No people, children, faces, text, logos, writing, screens, medical equipment, UI mockups, frames or watermark. Generate the photograph alone.

Flutter supplies the tint and contrast overlays; these are not embedded labels in the artwork. Decorative images ignore pointer and accessibility focus. High-contrast and large-text settings strengthen the overlays. Input and review cards retain opaque white surfaces. No network image loader, backdrop blur or animated full-screen effect is used.
