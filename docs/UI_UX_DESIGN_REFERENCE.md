# Universal UI/UX design reference

Reference notes used when making UI/UX decisions for toki-monitor — exact numbers, ratios, and formulas distilled from industry sources. Concrete tokens applied in the codebase live in `TokiMonitor/` source files; this document is the upstream principle library, not a per-component spec.

---

## The 8pt grid system

All spacing, sizing, padding, and margin values use multiples of 8.

**Primary scale:** 8, 16, 24, 32, 40, 48, 56, 64, 72, 80 px

**When to use the 4pt half-grid:**

- Icon spacing adjustments
- Small secondary text blocks
- Fine-tuning line-height alignment
- Values: 4, 12, 20, 28 px (odd multiples of 4)

**Rules:**

- Element dimensions: multiples of 8
- Padding and margin: multiples of 8 (or 4 for tight spaces)
- Font size: can vary freely, but line-height MUST be a multiple of 4
- Icon sizes: 16, 24, 32, 48 px (multiples of 8)
- Touch targets: minimum 48px (multiple of 8)

---

## Golden ratio (1.618)

**Layout division:** Split any container into 61.8% and 38.2%.

- Main content area : sidebar = 1.618 : 1
- For a 1200px layout: main = 742px, sidebar = 458px

**Element sizing:** Divide the larger element by 1.618 to get the smaller.

- If a heading is 32px, the subheading = 32 / 1.618 = ~20px
- If a card is 400px wide, related smaller card = 400 / 1.618 = ~247px

**Spacing:** Multiply an element's size by 1.618 for surrounding whitespace.

- 8px element spacing -> 8 x 1.618 = ~13px whitespace around it

---

## Typography scale

### Modular scale ratios

| Ratio | Name | Best for |
|-------|------|----------|
| 1.067 | Minor second | Dense UI, dashboards |
| 1.125 | Major second | Text-heavy apps, documentation |
| 1.200 | Minor third | General-purpose web (most common) |
| 1.250 | Major third | Editorial, balanced hierarchy |
| 1.333 | Perfect fourth | Magazine layouts, editorial |
| 1.414 | Augmented fourth | Bold hierarchies |
| 1.500 | Perfect fifth | Product pages, portfolios |
| 1.618 | Golden ratio | Landing pages, high-impact marketing |

### Example scale (base 16px, ratio 1.250)

```text
xs:   10px  (16 / 1.25^2)
sm:   13px  (16 / 1.25)
base: 16px
lg:   20px  (16 x 1.25)
xl:   25px  (16 x 1.25^2)
2xl:  31px  (16 x 1.25^3)
3xl:  39px  (16 x 1.25^4)
4xl:  49px  (16 x 1.25^5)
```

### Line height rules

| Text type | Line height multiplier |
|-----------|------------------------|
| Body text | 1.5x font size |
| Headings | 1.25x font size |
| Large display | 1.1-1.2x font size |
| Captions/small | 1.4-1.6x font size |

**Snap to 4pt grid:** Round line-height to nearest multiple of 4.

- 16px text x 1.5 = 24px line-height (already on grid)
- 14px text x 1.5 = 21px -> round to 20px or 24px

### Letter spacing

| Text size | Letter spacing |
|-----------|----------------|
| < 16px | +0.01 to +0.02em |
| 16-24px | 0em (default) |
| 24-48px | -0.01 to -0.02em |
| > 48px | -0.02 to -0.04em |

**Rule:** As text gets larger, tighten letter spacing proportionally.

### Line length

- Optimal: 45-75 characters per line
- Ideal target: 66 characters
- Absolute minimum: 30 characters
- Absolute maximum: 90 characters

---

## Color contrast (WCAG)

### Minimum contrast ratios

| Level | Normal text (< 18px) | Large text (>= 18px or >= 14px bold) | UI components |
|-------|----------------------|--------------------------------------|---------------|
| AA | 4.5:1 | 3:1 | 3:1 |
| AAA | 7:1 | 4.5:1 | 4.5:1 |

**Large text definition:** 18px (24px CSS) regular weight, or 14px (18.66px CSS) bold.

### Practical targets

- Body text on background: aim for 7:1 (AAA)
- Headings on background: minimum 3:1, aim for 4.5:1
- Placeholder text: minimum 4.5:1 (common violation)
- Icons and borders: minimum 3:1
- Focus indicators: minimum 3:1 against adjacent colors

---

## The 60-30-10 color rule

| Proportion | Role | Used for |
|------------|------|----------|
| 60% | Dominant color | Backgrounds, large surfaces |
| 30% | Secondary color | Headers, sidebars, cards, secondary surfaces |
| 10% | Accent color | CTAs, buttons, links, notifications, badges |

### Color harmony schemes

| Scheme | Wheel relationship | Character |
|--------|--------------------|-----------|
| Complementary | Opposite (180 degrees) | High contrast, energetic |
| Analogous | Adjacent (30 degrees apart) | Low contrast, harmonious |
| Triadic | Equidistant (120 degrees) | Vibrant, balanced |
| Split-complementary | 150 degrees apart | Contrast with nuance |

---

## Border radius

### Scale by element size

| Element smallest side | Radius | Examples |
|-----------------------|--------|----------|
| < 16px | 2-3px | Badges, tags, small chips |
| 16-32px | 4-6px | Inputs, small buttons |
| 32-56px | 8px | Standard buttons, list items |
| 56-100px | 12px | Cards, dialogs, message cards |
| 100-200px | 16-20px | Large cards, modals |
| > 200px | 24-32px | Hero sections, panels |

**Rule of thumb:** Radius = 5-10% of the element's smallest side.

### Nested corner radius formula

```text
inner_radius = outer_radius - padding
```

- Outer container: 24px radius, 16px padding -> Inner: 8px radius
- Outer container: 16px radius, 8px padding -> Inner: 8px radius
- If padding >= outer_radius, inner_radius = 0 (sharp corners)

---

## Whitespace and spacing hierarchy

### The inner < outer rule

An element's internal padding must be LESS THAN OR EQUAL TO its external margin. This creates visual grouping.

```text
Component padding: 16px
Gap between components: 24px  (must be >= 16px)
Section padding: 32px
Gap between sections: 48px   (must be >= 32px)
```

### Spacing scale (8pt grid)

| Token | Value | Use case |
|-------|-------|----------|
| 3xs | 2px | Hairline gaps, borders |
| 2xs | 4px | Icon-to-text gap, tight element spacing |
| xs | 8px | Related elements (heading + description) |
| sm | 12px | Input internal padding |
| md | 16px | Card internal padding, related groups |
| lg | 24px | Section padding, distinct element gaps |
| xl | 32px | Major section breaks |
| 2xl | 48px | Page-level section separation |
| 3xl | 64px | Hero spacing, major page divisions |

### Horizontal vs vertical padding

Horizontal padding = 2-3x vertical padding on the same element.

- Button: 12px vertical, 24px horizontal
- Card: 16px vertical, 24px horizontal
- Input field: 8-12px vertical, 12-16px horizontal

---

## Fitts's law and touch targets

### Minimum target sizes

| Context | Minimum size | Recommended size |
|---------|--------------|------------------|
| WCAG 2.2 AA | 24x24 CSS px | - |
| WCAG 2.1 AAA | 44x44 CSS px | - |
| iOS (Apple HIG) | 44x44 pt | 44x44 pt |
| Android (Material) | 48x48 dp | 48x48 dp |
| Desktop click | 24x24 px | 32x32 px |
| Desktop with mouse | 24x24 px | 32-40 px |

### Spacing between interactive elements

- Minimum gap between adjacent touch targets: 8px
- Recommended gap: 16px on mobile, 8px on desktop
- If targets are smaller than minimum, compensate with spacing

### Fitts's law summary

```text
Time = a + b * log2(Distance / Size + 1)
```

- Bigger targets are faster to hit
- Closer targets are faster to reach
- Corners and edges of screens are effectively infinite-size targets (cursor stops there)

---

## Gestalt principles (practical rules)

### Proximity

- Items within 8px of each other: perceived as a single unit
- Items 16-24px apart: perceived as related but distinct
- Items 32px+ apart: perceived as separate groups
- **Rule:** Space within a group should be LESS THAN HALF the space between groups

### Similarity

Perception priority (strongest to weakest):

1. Color (perceived first)
2. Size (perceived second)
3. Shape (perceived last)

Use color as your primary grouping tool, not shape.

### Closure

- Incomplete shapes are perceived as complete if >= 70% is visible
- Progress bars, loading indicators, and icon design exploit this

### Continuity

- Align elements along clear horizontal or vertical axes
- Items on a shared axis are perceived as belonging together
- Break alignment intentionally only to draw attention

---

## Visual hierarchy

### Size contrast

- Minimum 1.5x size difference for elements to appear distinct
- Recommended 2x or greater for clear hierarchy
- Example: body 16px, heading must be >= 24px (1.5x) to feel different

### Weight contrast

- Regular (400) vs Bold (700) creates clear distinction
- Regular (400) vs Medium (500) is too subtle for hierarchy
- Use maximum 2-3 font weights per interface

### Establishing hierarchy (ordered by impact)

1. Size (strongest differentiator)
2. Color/contrast
3. Weight
4. Position (top/left = higher importance in LTR languages)
5. Spacing (more space around = more importance)

---

## Icon sizing

### Standard icon sizes

| Context | Artwork size | Touch target |
|---------|--------------|--------------|
| Inline with text | 16px | - |
| Small toolbar | 20px | 32px |
| Standard toolbar | 24px | 44-48px |
| Navigation | 24-32px | 48px |
| Feature/illustration | 48-64px | - |

### Icon-to-text relationship

- Icon height should match the cap-height or x-height of adjacent text
- For 16px text: use 16-20px icons
- For 14px text: use 14-16px icons
- Gap between icon and text: 4-8px (4px for tight, 8px for comfortable)

### Icon canvas padding

- Keep artwork within 80% of the canvas
- Leave 10% margin on each side for optical alignment
- Round/circular icons can extend to 90% of canvas

---

## Information density (Miller's law)

### Working memory limits

- Classical: 7 plus or minus 2 items (5-9)
- Modern research: 3-4 items without chunking
- With chunking: up to 7 groups of chunked items

### Practical rules

| Element | Maximum count |
|---------|---------------|
| Top-level nav items | 5-7 |
| Dropdown menu items visible | 7-9 (then scroll) |
| Form fields per section | 5-7 |
| Dashboard widgets | 5-9 |
| Bullet points per list | 5-7 |
| Tabs in a tab bar | 3-5 mobile, 5-7 desktop |
| Action buttons visible | 1 primary + 1-2 secondary |

### Chunking strategy

Group related items into chunks of 3-4. Phone numbers use this: 555-867-5309 (3-3-4).

---

## Alignment rules

### Text alignment

| Content type | Alignment | Why |
|--------------|-----------|-----|
| Body text | Left | Consistent left edge for scanning |
| Numbers in tables | Right | Aligns decimal places for comparison |
| Short headings/CTAs | Center | Acceptable for 1-3 lines |
| Long text (> 3 lines) | Left | Center-aligned long text is hard to read |
| Dates | Left or right | Consistent with surrounding content |
| Currency | Right | Aligns decimal points |

### Element alignment

- Icons next to text: center-align vertically to text
- Form labels: right-align labels, left-align inputs (or top-align labels)
- Navigation items: left-align text, right-align counts/badges
- Card content: left-align all content to a single edge

---

## Responsive spacing

### Spacing scale multipliers by breakpoint

| Breakpoint | Width | Spacing multiplier |
|------------|-------|--------------------|
| Mobile (small) | < 480px | 0.75x |
| Mobile (large) | 480-767px | 1x (base) |
| Tablet | 768-1023px | 1x-1.25x |
| Desktop | 1024-1439px | 1.25x-1.5x |
| Large desktop | >= 1440px | 1.5x-2x |

### CSS clamp formula

```css
/* clamp(minimum, preferred, maximum) */
padding: clamp(16px, 4vw, 48px);
font-size: clamp(16px, 1.5vw + 10px, 24px);
gap: clamp(8px, 2vw, 24px);
```

**Rule:** Maximum font size should not exceed 2.5x the minimum for WCAG compliance.

### Container padding

| Container width | Horizontal padding |
|-----------------|--------------------|
| < 480px | 16px |
| 480-767px | 16-24px |
| 768-1023px | 24-32px |
| 1024-1439px | 32-48px |
| >= 1440px | 48-64px or auto-margin with max-width |

---

## Dark mode

### Background colors

| Surface level | Color | Use |
|---------------|-------|-----|
| Base background | #121212 | App background |
| Surface (elevated) | #1E1E1E | Cards, sheets |
| Raised surface | #252525 | Dialogs, popovers |
| Highest surface | #2C2C2C | Tooltips, menus |

**Never use pure black (#000000) as the main background.**

### Material Design elevation overlay (white on #121212)

Common levels (full table in Material spec):

| Elevation | White overlay opacity |
|-----------|-----------------------|
| 0dp | 0% |
| 1dp | 5% |
| 2dp | 7% |
| 4dp | 9% |
| 8dp | 12% |
| 16dp | 15% |
| 24dp | 16% |

### Text opacity on dark backgrounds

| Emphasis | White text opacity | Effective color (on #121212) |
|----------|--------------------|------------------------------|
| High | 87% | #DEDEDE |
| Medium | 60% | #999999 |
| Disabled | 38% | #626262 |

**Never use pure white (#FFFFFF) for body text on dark backgrounds.** Use 87% opacity white or ~#DEDEDE.

### Color adjustments for dark mode

- Reduce saturation by ~20% (HSL saturation points) compared to light mode
- Use lighter tints of brand colors (200-300 weight instead of 500-600)
- Maintain WCAG AA 4.5:1 contrast for all text
- Avoid saturated colors on dark backgrounds (causes visual vibration)

---

## Quick reference

Section pointers, not a replacement for the body:

1. 8pt grid — see [The 8pt grid system](#the-8pt-grid-system)
2. Inner padding < outer margin — see [Whitespace and spacing hierarchy](#whitespace-and-spacing-hierarchy)
3. Body text contrast 4.5:1, large/UI 3:1 — see [Color contrast (WCAG)](#color-contrast-wcag)
4. Touch targets ≥ 44px — see [Fitts's law and touch targets](#fittss-law-and-touch-targets)
5. Body line-height 1.5x, heading 1.25x — see [Typography scale](#typography-scale)
6. 60-30-10 color split — see [The 60-30-10 color rule](#the-60-30-10-color-rule)
7. Max 5-7 items before chunking — see [Information density (Miller's law)](#information-density-millers-law)
8. 1.5x size difference between hierarchy levels — see [Visual hierarchy](#visual-hierarchy)
9. Nested radius = outer − padding — see [Border radius](#border-radius)
10. Dark mode base #121212, text 87% white — see [Dark mode](#dark-mode)

---

## Sources

- [The golden ratio and UI design - NNGroup](https://www.nngroup.com/articles/golden-ratio-ui-design/)
- [Golden ratio in web design - Oivan](https://oivan.com/golden-ratio-in-web-design/)
- [8pt grid - Spec.fm](https://spec.fm/specifics/8-pt-grid)
- [Spacing best practices - Cieden](https://cieden.com/book/sub-atomic/spacing/spacing-best-practices)
- [Spacing, grids, and layouts - DesignSystems.com](https://www.designsystems.com/space-grids-and-layouts/)
- [Border radius guide - Telerik](https://www.telerik.com/design-system/docs/foundation/border-radius/usage/)
- [Nested border radius - Frontend Masters](https://frontendmasters.com/blog/the-classic-border-radius-advice-plus-an-unusual-trick/)
- [Corner radius system - Medium](https://medium.com/design-bootcamp/building-a-consistent-corner-radius-system-in-ui-1f86eed56dd3)
- [WCAG contrast minimum - W3C](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)
- [Color contrast accessibility guide](https://www.allaccessible.org/blog/color-contrast-accessibility-wcag-guide-2025)
- [Establishing a type scale - Cieden](https://cieden.com/book/sub-atomic/typography/establishing-a-type-scale)
- [Modular scale - Bounteous](https://www.bounteous.com/insights/2018/03/26/what-font-are-vertical-rhythm-and-modular-scale/)
- [60-30-10 rule - UX Planet](https://uxplanet.org/the-60-30-10-rule-a-foolproof-way-to-choose-colors-for-your-ui-design-d15625e56d25)
- [60-30-10 rule - Wix](https://www.wix.com/wixel/resources/60-30-10-color-rule)
- [Color harmonies in UI - Supercharge Design](https://supercharge.design/blog/color-harmonies-in-ui-in-depth-guide)
- [WCAG 2.5.8 target size minimum - W3C](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)
- [WCAG 2.5.5 target size - W3C](https://www.w3.org/WAI/WCAG21/Understanding/target-size.html)
- [Proximity principle - NNGroup](https://www.nngroup.com/articles/gestalt-proximity/)
- [Gestalt principles - IxDF](https://ixdf.org/literature/topics/gestalt-principles)
- [Dark mode best practices - Uxcel](https://uxcel.com/blog/12-principles-of-dark-mode-design-627)
- [Dark mode UI best practices - Atmos](https://atmos.style/blog/dark-mode-ui-best-practices)
- [Material Design dark theme - GitHub](https://github.com/material-components/material-components-android/blob/master/docs/theming/Dark.md)
- [Material Design elevation - M2](https://m2.material.io/design/environment/elevation.html)
- [Material Design shape - M3](https://m3.material.io/styles/shape/corner-radius-scale)
- [Miller's law - Laws of UX](https://lawsofux.com/millers-law/)
- [Visual hierarchy - IxDF](https://ixdf.org/literature/topics/visual-hierarchy)
- [Text alignment best practices - Prototypr](https://blog.prototypr.io/text-alignment-best-practises-c4114daf1a9b)
- [Fluid typography with CSS clamp - Smashing Magazine](https://www.smashingmagazine.com/2022/01/modern-fluid-typography-css-clamp/)
- [Icon size guidelines - DEV Community](https://dev.to/albert_nahas_cdc8469a6ae8/icon-size-guidelines-for-web-and-mobile-applications-in1)
- [IBM Design Language - UI icons](https://www.ibm.com/design/language/iconography/ui-icons/usage/)
- [Optical effects in UI - Medium](https://medium.com/design-bridges/optical-effects-9fca82b4cd9a)
