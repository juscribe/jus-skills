# Charts — which ones earn their place, and how to hand-author them

Read at the moment you draw something, after step 4's rule that charts are inline SVG
with no library, no CDN and no network.

### Which cuts earn a chart

| Chart | For |
| --- | --- |
| Horizontal bars | Effort by kind of work (section 3) |
| Column series | Velocity against the preceding iterations; **hours of the day carrying work** (section 5), one column per hour |
| Strip or dot plot | Cycle-time distribution — where the tail is, which a mean hides; elapsed time within one point value (section 4), which is where a miscalibrated scale shows |
| Nothing | Everything else |

**A chart of four values is a table with extra steps.** Committed vs accepted is two numbers; write them large and move on.

### A bar row, complete

```html
<svg viewBox="0 0 600 24" role="img" aria-label="Bug fixing: 34 points, 27% of the iteration">
  <rect x="0" y="4" width="600" height="16" rx="3" fill="var(--track)" />
  <rect x="0" y="4" width="162" height="16" rx="3" fill="var(--accent)" />
  <text x="170" y="16" font-size="12" fill="var(--ink)">Bug fixing — 34 pts (27%)</text>
</svg>
```

**Compute the width yourself** — `width = 600 * value / max` — and round to one decimal. Nothing in the page does arithmetic at render time, which is what makes the numbers checkable in step 5.

⚠️ **Every chart carries its numbers in text as well.** A bar whose value appears only as a length is unreadable when printed, screenshotted small, or read aloud. The `aria-label` is not optional either.

### ⚠️ THE `viewBox` MUST CONTAIN EVERY COORDINATE THE CHART DRAWS

**This is the failure that actually ships.** A column chart is authored from the bars outward — the bars are placed, then the value labels above them, then the axis labels below — and the `viewBox` is written once, early, from the plot area. Anything added afterwards outside that box is **clipped silently**: no error, no warning, and the chart still looks like a chart.

```
viewBox="-44 -14 678 152"      →  y runs from -14 to 138
<text y="144">09</text>        →  six pixels below the floor. Clipped.
```

**Measured on a real report:** every hour label on the busiest chart was cut in half, and the section it belonged to was the one about when the work happened — so the chart lost the axis that made it readable, and nothing about the source looked wrong.

**The arithmetic, once, for each box:**

- horizontal extent is `minX` … `minX + width`; vertical is `minY` … `minY + height`
- **a `<text>` needs more than its own `y`.** The `y` is the baseline; descenders fall about `0.25em` below it and cap height rises about `0.75em` above. Give a label at `font-size: 11` at least 4px of floor beneath it.
- `text-anchor="middle"` centres horizontally on `x`, so a label at the last column needs roughly half its width to the right of that `x` still inside the box.

**Size the box to the drawing, not the drawing to the box.** Compute the extremes as you place things, then write the `viewBox` last.

### Colour that survives both themes

Define the palette once as custom properties, then override it for dark. Do not put a colour's only definition inside the media query.

```css
:root {
  --bg: #fbfbf9; --ink: #1c1c1a; --muted: #6b6b66;
  --track: #e7e7e2; --accent: #3b6ea5; --rule: #dcdcd6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14140f; --ink: #ebebe5; --muted: #9a9a92;
    --track: #2a2a24; --accent: #7aa7d4; --rule: #33332c;
  }
}
body { background: var(--bg); color: var(--ink); }
```

⚠️ **Give `body` an explicit background.** A transparent one borrows whatever is behind the page, and a light report on a dark ground is unreadable in exactly the place you will not test it.
