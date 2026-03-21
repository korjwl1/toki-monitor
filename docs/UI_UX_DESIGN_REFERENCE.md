# Universal UI/UX Design Reference

Exact numbers, ratios, and formulas for producing good design mechanically.

---

## 1. The 8pt Grid System

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

## 2. Golden Ratio (1.618)

**Layout division:** Split any container into 61.8% and 38.2%.
- Main content area : sidebar = 1.618 : 1
- For a 1200px layout: main = 742px, sidebar = 458px

**Element sizing:** Divide the larger element by 1.618 to get the smaller.
- If a heading is 32px, the subheading = 32 / 1.618 = ~20px
- If a card is 400px wide, related smaller card = 400 / 1.618 = ~247px

**Spacing:** Multiply an element's size by 1.618 for surrounding whitespace.
- 8px element spacing -> 8 x 1.618 = ~13px whitespace around it

---

## 3. Typography Scale

### Modular Scale Ratios

| Ratio | Name             | Best For                                |
|-------|------------------|-----------------------------------------|
| 1.067 | Minor Second    | Dense UI, dashboards                     |
| 1.125 | Major Second    | Text-heavy apps, documentation           |
| 1.200 | Minor Third     | General-purpose web (most common)        |
| 1.250 | Major Third     | Editorial, balanced hierarchy            |
| 1.333 | Perfect Fourth  | Magazine layouts, editorial              |
| 1.414 | Augmented Fourth| Bold hierarchies                         |
| 1.500 | Perfect Fifth   | Product pages, portfolios                |
| 1.618 | Golden Ratio    | Landing pages, high-impact marketing     |

### Example Scale (base 16px, ratio 1.250)

```
xs:   10px  (16 / 1.25^2)
sm:   13px  (16 / 1.25)
base: 16px
lg:   20px  (16 x 1.25)
xl:   25px  (16 x 1.25^2)
2xl:  31px  (16 x 1.25^3)
3xl:  39px  (16 x 1.25^4)
4xl:  49px  (16 x 1.25^5)
```

### Line Height Rules

| Text Type        | Line Height Multiplier |
|------------------|----------------------|
| Body text        | 1.5x font size       |
| Headings         | 1.25x font size      |
| Large display    | 1.1-1.2x font size   |
| Captions/small   | 1.4-1.6x font size   |

**Snap to 4pt grid:** Round line-height to nearest multiple of 4.
- 16px text x 1.5 = 24px line-height (already on grid)
- 14px text x 1.5 = 21px -> round to 20px or 24px

### Letter Spacing

| Text Size | Letter Spacing        |
|-----------|-----------------------|
| < 16px    | +0.01 to +0.02em     |
| 16-24px   | 0em (default)         |
| 24-48px   | -0.01 to -0.02em     |
| > 48px    | -0.02 to -0.04em     |

**Rule:** As text gets larger, tighten letter spacing proportionally.

### Line Length

- Optimal: 45-75 characters per line
- Ideal target: 66 characters
- Absolute minimum: 30 characters
- Absolute maximum: 90 characters

---

## 4. Color Contrast (WCAG)

### Minimum Contrast Ratios

| Level | Normal Text (< 18px) | Large Text (>= 18px or >= 14px bold) | UI Components |
|-------|---------------------|--------------------------------------|---------------|
| AA    | 4.5:1               | 3:1                                  | 3:1           |
| AAA   | 7:1                 | 4.5:1                                | 4.5:1         |

**Large text definition:** 18px (24px CSS) regular weight, or 14px (18.66px CSS) bold.

### Practical Targets

- Body text on background: aim for 7:1 (AAA)
- Headings on background: minimum 3:1, aim for 4.5:1
- Placeholder text: minimum 4.5:1 (common violation)
- Icons and borders: minimum 3:1
- Focus indicators: minimum 3:1 against adjacent colors

---

## 5. The 60-30-10 Color Rule

| Proportion | Role            | Used For                                    |
|------------|-----------------|---------------------------------------------|
| 60%        | Dominant color  | Backgrounds, large surfaces                 |
| 30%        | Secondary color | Headers, sidebars, cards, secondary surfaces|
| 10%        | Accent color    | CTAs, buttons, links, notifications, badges |

### Color Harmony Schemes

| Scheme         | Wheel Relationship          | Character               |
|----------------|----------------------------|-------------------------|
| Complementary  | Opposite (180 degrees)            | High contrast, energetic |
| Analogous      | Adjacent (30 degrees apart) | Low contrast, harmonious |
| Triadic        | Equidistant (120 degrees)   | Vibrant, balanced        |
| Split-complementary | 150 degrees apart     | Contrast with nuance     |

---

## 6. Border Radius

### Scale by Element Size

| Element Smallest Side | Radius        | Examples                        |
|-----------------------|---------------|---------------------------------|
| < 16px                | 2-3px         | Badges, tags, small chips       |
| 16-32px               | 4-6px         | Inputs, small buttons           |
| 32-56px               | 8px           | Standard buttons, list items    |
| 56-100px              | 12px          | Cards, dialogs, message cards   |
| 100-200px             | 16-20px       | Large cards, modals             |
| > 200px               | 24-32px       | Hero sections, panels           |

**Rule of thumb:** Radius = 5-10% of the element's smallest side.

### Nested Corner Radius Formula

```
inner_radius = outer_radius - padding
```

- Outer container: 24px radius, 16px padding -> Inner: 8px radius
- Outer container: 16px radius, 8px padding -> Inner: 8px radius
- If padding >= outer_radius, inner_radius = 0 (sharp corners)

---

## 7. Whitespace and Spacing Hierarchy

### The Inner < Outer Rule

An element's internal padding must be LESS THAN OR EQUAL TO its external margin. This creates visual grouping.

```
Component padding: 16px
Gap between components: 24px  (must be >= 16px)
Section padding: 32px
Gap between sections: 48px   (must be >= 32px)
```

### Spacing Scale (8pt Grid)

| Token | Value | Use Case                                  |
|-------|-------|-------------------------------------------|
| 3xs   | 2px   | Hairline gaps, borders                     |
| 2xs   | 4px   | Icon-to-text gap, tight element spacing    |
| xs    | 8px   | Related elements (heading + description)   |
| sm    | 12px  | Input internal padding                     |
| md    | 16px  | Card internal padding, related groups      |
| lg    | 24px  | Section padding, distinct element gaps     |
| xl    | 32px  | Major section breaks                       |
| 2xl   | 48px  | Page-level section separation              |
| 3xl   | 64px  | Hero spacing, major page divisions         |

### Horizontal vs Vertical Padding

Horizontal padding = 2-3x vertical padding on the same element.
- Button: 12px vertical, 24px horizontal
- Card: 16px vertical, 24px horizontal
- Input field: 8-12px vertical, 12-16px horizontal

---

## 8. Fitts's Law and Touch Targets

### Minimum Target Sizes

| Context             | Minimum Size | Recommended Size |
|---------------------|-------------|-----------------|
| WCAG 2.2 AA         | 24x24 CSS px | -               |
| WCAG 2.1 AAA        | 44x44 CSS px | -               |
| iOS (Apple HIG)     | 44x44 pt     | 44x44 pt        |
| Android (Material)  | 48x48 dp     | 48x48 dp        |
| Desktop click       | 24x24 px     | 32x32 px        |
| Desktop with mouse  | 24x24 px     | 32-40 px        |

### Spacing Between Interactive Elements

- Minimum gap between adjacent touch targets: 8px
- Recommended gap: 16px on mobile, 8px on desktop
- If targets are smaller than minimum, compensate with spacing

### Fitts's Law Summary

```
Time = a + b * log2(Distance / Size + 1)
```

- Bigger targets are faster to hit
- Closer targets are faster to reach
- Corners and edges of screens are effectively infinite-size targets (cursor stops there)

---

## 9. Gestalt Principles (Practical Rules)

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

## 10. Visual Hierarchy

### Size Contrast

- Minimum 1.5x size difference for elements to appear distinct
- Recommended 2x or greater for clear hierarchy
- Example: body 16px, heading must be >= 24px (1.5x) to feel different

### Weight Contrast

- Regular (400) vs Bold (700) creates clear distinction
- Regular (400) vs Medium (500) is too subtle for hierarchy
- Use maximum 2-3 font weights per interface

### Establishing Hierarchy (ordered by impact)

1. Size (strongest differentiator)
2. Color/contrast
3. Weight
4. Position (top/left = higher importance in LTR languages)
5. Spacing (more space around = more importance)

---

## 11. Icon Sizing

### Standard Icon Sizes

| Context             | Artwork Size | Touch Target |
|---------------------|-------------|-------------|
| Inline with text    | 16px        | -           |
| Small toolbar       | 20px        | 32px        |
| Standard toolbar    | 24px        | 44-48px     |
| Navigation          | 24-32px     | 48px        |
| Feature/illustration| 48-64px     | -           |

### Icon-to-Text Relationship

- Icon height should match the cap-height or x-height of adjacent text
- For 16px text: use 16-20px icons
- For 14px text: use 14-16px icons
- Gap between icon and text: 4-8px (4px for tight, 8px for comfortable)

### Icon Canvas Padding

- Keep artwork within 80% of the canvas
- Leave 10% margin on each side for optical alignment
- Round/circular icons can extend to 90% of canvas

---

## 12. Information Density (Miller's Law)

### Working Memory Limits

- Classical: 7 plus or minus 2 items (5-9)
- Modern research: 3-4 items without chunking
- With chunking: up to 7 groups of chunked items

### Practical Rules

| Element                    | Maximum Count      |
|----------------------------|-------------------|
| Top-level nav items        | 5-7               |
| Dropdown menu items visible| 7-9 (then scroll) |
| Form fields per section    | 5-7               |
| Dashboard widgets          | 5-9               |
| Bullet points per list     | 5-7               |
| Tabs in a tab bar          | 3-5 (mobile), 5-7 (desktop) |
| Action buttons visible     | 1 primary + 1-2 secondary |

### Chunking Strategy

Group related items into chunks of 3-4. Phone numbers use this: 555-867-5309 (3-3-4).

---

## 13. Alignment Rules

### Text Alignment

| Content Type          | Alignment    | Why                                         |
|-----------------------|-------------|---------------------------------------------|
| Body text             | Left        | Creates consistent left edge for scanning    |
| Numbers in tables     | Right       | Aligns decimal places for comparison          |
| Short headings/CTAs   | Center      | Draws attention, acceptable for 1-3 lines    |
| Long text (> 3 lines) | Left        | Center-aligned long text is hard to read     |
| Dates                 | Left or Right| Consistent with surrounding content          |
| Currency              | Right       | Aligns decimal points                        |

### Element Alignment

- Icons next to text: center-align vertically to text
- Form labels: right-align labels, left-align inputs (or top-align labels)
- Navigation items: left-align text, right-align counts/badges
- Card content: left-align all content to a single edge

---

## 14. Responsive Spacing

### Spacing Scale Multipliers by Breakpoint

| Breakpoint       | Width        | Spacing Multiplier |
|------------------|-------------|-------------------|
| Mobile (small)   | < 480px     | 0.75x             |
| Mobile (large)   | 480-767px   | 1x (base)         |
| Tablet           | 768-1023px  | 1x-1.25x          |
| Desktop          | 1024-1439px | 1.25x-1.5x        |
| Large desktop    | >= 1440px   | 1.5x-2x           |

### CSS Clamp Formula

```css
/* clamp(minimum, preferred, maximum) */
padding: clamp(16px, 4vw, 48px);
font-size: clamp(16px, 1.5vw + 10px, 24px);
gap: clamp(8px, 2vw, 24px);
```

**Rule:** Maximum font size should not exceed 2.5x the minimum for WCAG compliance.

### Container Padding

| Container Width  | Horizontal Padding |
|-----------------|--------------------|
| < 480px         | 16px               |
| 480-767px       | 16-24px            |
| 768-1023px      | 24-32px            |
| 1024-1439px     | 32-48px            |
| >= 1440px       | 48-64px or auto-margin with max-width |

---

## 15. Dark Mode

### Background Colors

| Surface Level       | Color     | Use                              |
|---------------------|-----------|----------------------------------|
| Base background      | #121212  | App background                    |
| Surface (elevated)   | #1E1E1E  | Cards, sheets                     |
| Raised surface       | #252525  | Dialogs, popovers                |
| Highest surface      | #2C2C2C  | Tooltips, menus                   |

**Never use pure black (#000000) as the main background.**

### Material Design Elevation Overlay (White on #121212)

| Elevation | White Overlay Opacity |
|-----------|----------------------|
| 0dp       | 0%                   |
| 1dp       | 5%                   |
| 2dp       | 7%                   |
| 3dp       | 8%                   |
| 4dp       | 9%                   |
| 6dp       | 11%                  |
| 8dp       | 12%                  |
| 12dp      | 14%                  |
| 16dp      | 15%                  |
| 24dp      | 16%                  |

### Text Opacity on Dark Backgrounds

| Emphasis    | White Text Opacity | Effective Color (on #121212) |
|-------------|-------------------|------------------------------|
| High        | 87%               | #DEDEDE                      |
| Medium      | 60%               | #999999                      |
| Disabled    | 38%               | #626262                      |

**Never use pure white (#FFFFFF) for body text on dark backgrounds.** Use 87% opacity white or ~#DEDEDE.

### Color Adjustments for Dark Mode

- Reduce saturation by ~20% (HSL saturation points) compared to light mode
- Use lighter tints of brand colors (200-300 weight instead of 500-600)
- Maintain WCAG AA 4.5:1 contrast for all text
- Avoid saturated colors on dark backgrounds (causes visual vibration)

---

## Quick Reference: The 10 Commandments

1. **Use the 8pt grid.** All spacing = multiples of 8 (4 for fine adjustment).
2. **Inner padding < outer margin.** Always. No exceptions.
3. **Minimum 4.5:1 contrast** for body text. 3:1 for large text and UI components.
4. **Touch targets >= 44px.** Compensate smaller icons with padding.
5. **Body line-height = 1.5x.** Heading line-height = 1.25x.
6. **60-30-10 color split.** Background, secondary, accent.
7. **Max 5-7 items** before chunking or progressive disclosure.
8. **1.5x minimum size difference** between hierarchy levels.
9. **Inner radius = outer radius - padding** for nested rounded corners.
10. **Dark mode = #121212 base**, never pure black. Text at 87% white, never pure white.

---

## Sources

- [The Golden Ratio and UI Design - NNGroup](https://www.nngroup.com/articles/golden-ratio-ui-design/)
- [Golden Ratio in Web Design - Oivan](https://oivan.com/golden-ratio-in-web-design/)
- [8pt Grid - Spec.fm](https://spec.fm/specifics/8-pt-grid)
- [Spacing Best Practices - Cieden](https://cieden.com/book/sub-atomic/spacing/spacing-best-practices)
- [Spacing, Grids, and Layouts - DesignSystems.com](https://www.designsystems.com/space-grids-and-layouts/)
- [Border Radius Guide - Telerik](https://www.telerik.com/design-system/docs/foundation/border-radius/usage/)
- [Nested Border Radius - Frontend Masters](https://frontendmasters.com/blog/the-classic-border-radius-advice-plus-an-unusual-trick/)
- [Corner Radius System - Medium](https://medium.com/design-bootcamp/building-a-consistent-corner-radius-system-in-ui-1f86eed56dd3)
- [WCAG Contrast Minimum - W3C](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)
- [Color Contrast Accessibility Guide](https://www.allaccessible.org/blog/color-contrast-accessibility-wcag-guide-2025)
- [Establishing a Type Scale - Cieden](https://cieden.com/book/sub-atomic/typography/establishing-a-type-scale)
- [Modular Scale - Bounteous](https://www.bounteous.com/insights/2018/03/26/what-font-are-vertical-rhythm-and-modular-scale/)
- [60-30-10 Rule - UX Planet](https://uxplanet.org/the-60-30-10-rule-a-foolproof-way-to-choose-colors-for-your-ui-design-d15625e56d25)
- [60-30-10 Rule - Wix](https://www.wix.com/wixel/resources/60-30-10-color-rule)
- [Color Harmonies in UI - Supercharge Design](https://supercharge.design/blog/color-harmonies-in-ui-in-depth-guide)
- [WCAG 2.5.8 Target Size Minimum - W3C](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)
- [WCAG 2.5.5 Target Size - W3C](https://www.w3.org/WAI/WCAG21/Understanding/target-size.html)
- [Proximity Principle - NNGroup](https://www.nngroup.com/articles/gestalt-proximity/)
- [Gestalt Principles - IxDF](https://ixdf.org/literature/topics/gestalt-principles)
- [Dark Mode Best Practices - Uxcel](https://uxcel.com/blog/12-principles-of-dark-mode-design-627)
- [Dark Mode UI Best Practices - Atmos](https://atmos.style/blog/dark-mode-ui-best-practices)
- [Material Design Dark Theme - GitHub](https://github.com/material-components/material-components-android/blob/master/docs/theming/Dark.md)
- [Material Design Elevation - M2](https://m2.material.io/design/environment/elevation.html)
- [Material Design Shape - M3](https://m3.material.io/styles/shape/corner-radius-scale)
- [Miller's Law - Laws of UX](https://lawsofux.com/millers-law/)
- [Visual Hierarchy - IxDF](https://ixdf.org/literature/topics/visual-hierarchy)
- [Text Alignment Best Practices - Prototypr](https://blog.prototypr.io/text-alignment-best-practises-c4114daf1a9b)
- [Fluid Typography with CSS Clamp - Smashing Magazine](https://www.smashingmagazine.com/2022/01/modern-fluid-typography-css-clamp/)
- [Icon Size Guidelines - DEV Community](https://dev.to/albert_nahas_cdc8469a6ae8/icon-size-guidelines-for-web-and-mobile-applications-in1)
- [IBM Design Language - UI Icons](https://www.ibm.com/design/language/iconography/ui-icons/usage/)
- [Optical Effects in UI - Medium](https://medium.com/design-bridges/optical-effects-9fca82b4cd9a)
