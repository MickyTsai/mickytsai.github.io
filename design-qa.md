# Design QA — Editorial Home

## Evidence

- Source visual truth: `/Users/micky/.codex/generated_images/019fa160-248b-7241-a2c7-8f162210f6c5/exec-05d68904-f8fe-4623-8e65-7cf09111af59.png`
- Browser-rendered implementation: `/Users/micky/.codex/visualizations/2026/07/27/019fa160-248b-7241-a2c7-8f162210f6c5/editorial-home-qa/qa-home-final-viewport.jpg`
- Full-page implementation: `/Users/micky/.codex/visualizations/2026/07/27/019fa160-248b-7241-a2c7-8f162210f6c5/editorial-home-qa/qa-home-final.png`
- Mobile implementation: `/Users/micky/.codex/visualizations/2026/07/27/019fa160-248b-7241-a2c7-8f162210f6c5/editorial-home-qa/qa-home-mobile.png`
- Side-by-side comparison: `/Users/micky/.codex/visualizations/2026/07/27/019fa160-248b-7241-a2c7-8f162210f6c5/editorial-home-qa/qa-home-comparison.jpg`
- Reference pixels: 1536 × 1024
- Implementation pixels: 1440 × 1024 at a 1440 × 1024 CSS viewport and device scale factor 1
- Density normalization: the reference was resized with center-cover to 1440 × 1024; the implementation was captured at 1440 × 1024.
- State: homepage, light editorial theme, top of page, no search query, mobile drawer closed.

## Full-view comparison

The side-by-side comparison confirms the same three-rail desktop composition, warm paper background, thin separators, high-contrast serif typography, coral accent, large editorial feature, three-column article grid, compact metadata, left profile navigation, and right utility rail. Existing article artwork replaces the conceptual mock imagery while preserving its crop ratios and visual density.

## Focused-region comparison

The hero and first article row were inspected at full resolution because they contain the highest-fidelity surfaces: title wrapping, metadata spacing, image crop, grid alignment, right-rail density, and accent usage. A separate mobile capture verifies the responsive single-column state and menu control.

## Required fidelity surfaces

- Fonts and typography: passed. System editorial serif and sans-serif fallbacks preserve the source hierarchy, optical contrast, line height, and metadata treatment. Chinese title sizing was reduced after the first pass to avoid an oversized four-line hero.
- Spacing and layout rhythm: passed. Rail widths, main gutters, hero proportions, separators, card gaps, radii, and vertical rhythm closely follow the source. Desktop horizontal overflow is absent.
- Colors and visual tokens: passed. Warm off-white, near-black ink, muted gray, pale divider, and coral accent are consistently mapped to CSS variables with sufficient contrast.
- Image quality and asset fidelity: passed. All visible media uses existing full-resolution article assets with `object-fit: cover`; no placeholders, CSS art, or synthetic icon drawings are present. Font Awesome provides the interface icons.
- Copy and content: passed. The conceptual English mock copy was intentionally replaced by real site titles, descriptions, dates, reading times, categories, and social destinations.
- Responsiveness and accessibility: passed. The 390 × 844 breakpoint uses a single-column layout with no horizontal overflow. Keyboard focus styles, landmark labels, button state, image alt handling, reduced-motion handling, and search empty state are present.
- Interactions: passed. Article search filters to the matching card, mobile drawer opens/closes with synchronized `aria-expanded`, navigation links resolve correctly, and the browser console is error-free.

## Comparison history

### Pass 1

- P2: the Chinese hero title occupied four oversized lines and changed the source's above-the-fold balance.
- P2: category and tag URL generation slugified the complete path, removing the directory separator.
- P2: Chirpy's shared script expected legacy controls and logged a null-element error on the custom homepage.

Fixes:

- Reduced the hero display size from a 62px maximum to 52px.
- Slugified only the category/tag value before assembling each URL.
- Added a hidden compatibility layer for the Chirpy shared script without altering the visible design.

### Pass 2

- Post-fix browser capture shows the corrected title rhythm, valid `/categories/.../` and `/tags/.../` paths, and no console errors.
- No actionable P0, P1, or P2 differences remain.

## Follow-up polish

- P3: the reference shows six secondary cards; the implementation shows five because only five remaining posts currently have real cover artwork. The grid will fill naturally as new image-backed posts are added.

## Final result

final result: passed
