---
name: scannable
description: Make any document readable at a glance, for use under pressure (mid-call, mid-incident, mid-task), in any format — Claude artifacts, HTML, PDF, Markdown/Obsidian, PowerPoint/slides, Word/Google Docs, email, chat, terminal output. Use when writing or revising a cheatsheet, glance sheet, crib sheet, runbook, reference card, briefing, slide, or any note the user will scan rather than read, or when they say something is hard to scan, too dense, or has too many paragraphs.
---

# Scannable

Readers under pressure scan; they don't read. Left alone, Claude writes paragraphs, packs three facts into one bullet, and lets headings and body text blur together. The principles below hold for every format. Each format then has its own way of carrying them out (see **By target**).

## Principles

### Text
- No paragraphs. If a block has two sentences, make it two bullets.
- One fact per bullet. Split at "and", ";", ":" or a second clause, even if that doubles the bullet count.
- Cut bullets to the words someone would actually say or look for. Drop framing like "I'd say that…".
- Quotes go in their own sub-bullet under the line they support, never inline after a colon.
- Put the action word or number first: "→ ask about funding", "Shipped 07-15".
- "Don't" items go in their own list with a distinct marker (✗), apart from the "do" list.

### Hierarchy you can see
Each level must look different without being read. Use every signal the format allows, in this order of reliability:
1. **Indentation.** Body sits indented under its heading and never lines up with it. Sub-points are indented further.
2. **Weight and size.** Headings bold/larger; lead lines bold; sub-points and asides smaller.
3. **Color**, where the format has it: section title in an accent color, subheading in a deep tone of it, bullets in ink, sub-points and asides softer. Color is a second signal. Hierarchy must still read in grayscale or print.
4. **Markers.** Different bullet glyphs per level (•, –), ✗ for don'ts, → for actions.

Structured stories (STAR and the like): bold S/A/R lead lines; follow-on lines as indented, softer sub-points; a gap before each new letter.

Numbers in a mono or bold face (accent color if available), so they jump out.

### Space
- A visible gap between subsections (about one blank line, ~16px), and a smaller one between groups such as S/A/R (~10px).
- Tight spacing within a group (~3–4px), so groups read as units.

## By target

### Claude artifacts and HTML pages
Load `artifact-design` as usual. Then:

```css
:root{--accent:#8a2f4a;--head:#4e1a2c;--ink:#2a1a20;--sub:#5f4c54;--rule:#d9c3cb}
/* plus dark-mode overrides for each token */
h2{color:var(--accent);font-size:13px;text-transform:uppercase;letter-spacing:.08em}
h3{color:var(--head);font-size:15px;margin:16px 0 3px}
h3:first-of-type{margin-top:2px}
.panel{display:grid;gap:10px}
.panel>ul,.panel>ol{padding-left:1.9em;border-left:2px solid var(--rule);margin-left:2px}
.panel>ul.muted{color:var(--sub);font-size:13.5px}
li::marker{color:var(--accent)}
.n{font-family:var(--mono);font-weight:700;color:var(--accent)}

/* STAR: <li><b>S</b> lead</li> then <li><b></b> continuation</li> */
.star{list-style:none;padding:0;display:grid;gap:3px}
.star li{padding-left:1.6em;text-indent:-1.6em}
.star b{display:inline-block;width:1.2em;color:var(--accent);text-indent:0}
.star li:not(:has(>b:empty)){font-weight:600}
.star li:not(:has(>b:empty)):not(:first-child){margin-top:10px}
.star li:has(>b:empty){padding-left:3.2em;text-indent:-1.2em;color:var(--sub)}
.star li:has(>b:empty)>b::before{content:"–";color:var(--rule)}
```

Gotcha: `text-indent` is inherited by inline-block children. Without `text-indent:0` on the letter, a hanging indent pushes the letters past the card edge.

### PDF
- Build it as HTML with the CSS above, then print it (headless Chrome or Playwright `page.pdf`).
- Add `@media print`: keep the colors (`print-color-adjust: exact`), drop sticky nav and filter controls, and use `break-inside: avoid` on cards and story groups so no group splits across pages.
- Check the rendered pages, not the HTML. Look for orphaned headings at page bottoms.
- If the PDF will be printed, make sure the hierarchy survives grayscale.

### Markdown (Obsidian, READMEs, GitHub)
- Markdown has no color, so indentation and weight do all the work.
- `##` for sections, `###` for subsections, nested lists for levels (2 or 4 spaces, consistent).
- Bold the lead word of a top-level bullet; no bold on sub-bullets.
- A blank line before each heading. No blank lines inside a list, or it renders loose.
- One list item per line, never hard-wrapped.
- Obsidian callouts (`> [!warning]`) for the don'ts block, if wanted.

### PowerPoint, Keynote, Google Slides
Use the `pptx` skill (or the Slides artifact type) for mechanics. Then:
- Use the template's built-in bullet levels (python-pptx `paragraph.level = 0/1/2`). Never fake indentation with spaces.
- Level 0 bold in ink; level 1 a step smaller in a softer color.
- Set `space_before` on level-0 paragraphs for gaps between groups, not empty paragraphs.
- No more than about 6 bullets on a slide; split rather than shrink the font.
- The title is the takeaway ("94% resolved before money moved"), not a topic ("Results").
- Render to images and look at them. Text overflow is the usual failure.

### Word, Google Docs, Claude Docs
- Use real list styles (List Bullet, List Bullet 2) and heading styles. Never use manual tabs or spaces.
- Paragraph spacing via style "space before", not blank lines.
- Color via heading styles, not hand-colored runs, so it stays consistent.

### Email, chat (Slack), terminal, plain text
- No color and often no markup, so use indentation, blank lines and markers.
- One blank line between groups; indent sub-points with two spaces and "–".
- Lead word in CAPS or **bold** (if the client renders it) to mark a group.
- Keep lines short enough not to wrap in the target client.
- In messages meant for pasting, use plain paragraphs and lists; no blockquote markup.

## Check before handing over
- Any element with more than one sentence? Split it.
- Squint at the rendered output (screenshot, PDF page, slide image, preview), not the source. Can you tell a heading from a bullet from a sub-point without reading?
- Grayscale or plain-text version still readable?
- Is every quote and number findable in under two seconds?
