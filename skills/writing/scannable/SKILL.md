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

If the host has its own artifact design guidance (for Claude, the `artifact-design` skill), load it first. Then:

```css
:root{--accent:#8a2f4a;--head:#4e1a2c;--ink:#2a1a20;--sub:#5f4c54;--rule:#d9c3cb;--mono:ui-monospace,Menlo,Consolas,monospace}
/* dark mode: redefine the color tokens above under prefers-color-scheme: dark */
h2{color:var(--accent);font-size:13px;text-transform:uppercase;letter-spacing:.08em}
.panel>*{margin:0}
.panel>h3{color:var(--head);font-size:15px;margin:16px 0 3px} /* 16px above a subsection, 3px to its list */
.panel>h2{margin-bottom:6px}
.panel>h2+h3{margin-top:0}
.panel>h2:not(:first-child){margin-top:16px}
.panel>:is(ul,ol)+:is(ul,ol){margin-top:10px} /* reset above removes the default gap between lists */
.panel>.muted{margin-top:10px;color:var(--sub);font-size:13.5px}
.panel>ul:not(.star),.panel>ol{padding-left:1.9em;border-left:2px solid var(--rule);margin-left:2px}
li::marker{color:var(--accent)}
.n{font-family:var(--mono);font-weight:700;color:var(--accent)}

/* STAR: <li><b>S</b> lead</li> then <li><b></b> continuation</li> */
.star{list-style:none;padding:0;display:grid;gap:3px} /* 3px within a group */
.star li{padding-left:1.6em;text-indent:-1.6em}
.star b{display:inline-block;width:1.2em;color:var(--accent);text-indent:0}
.star li:not(:has(>b:empty)){font-weight:600}
.star li:not(:has(>b:empty)):not(:first-child){margin-top:7px} /* adds to the 3px gap: 10px between groups */
.star li:has(>b:empty){padding-left:3.2em;text-indent:-1.2em;color:var(--sub)}
.star li:has(>b:empty)>b::before{content:"–";color:var(--rule)}
```

Gotcha: `text-indent` is inherited by inline-block children. Without `text-indent:0` on the letter, a hanging indent pushes the letters past the card edge.

### PDF

- Build it as HTML with the CSS above, then print it with headless Chrome or Playwright `page.pdf(print_background=True)`. Without that flag every background color is dropped.
- Add print rules for the page's own nav, card and story elements:

```css
@media print{
  :root{print-color-adjust:exact;-webkit-print-color-adjust:exact}
  nav{display:none}                       /* sticky nav, filter controls */
  .star,.panel>ul,.panel>ol{break-inside:avoid} /* no group split across pages */
  h2,h3{break-after:avoid}                /* no heading stranded at a page bottom */
}
```

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

If a `pptx` skill or Slides artifact type is available, use it for mechanics. Then:

- Use the template's built-in bullet levels. Never fake indentation with spaces.
  - python-pptx: `paragraph.level = 0/1/2`
  - Keynote, Google Slides: Tab / Shift-Tab in a bulleted text box
- Level 0 bold in ink; level 1 a step smaller in a softer color.
- Gaps between groups via paragraph "space before" (python-pptx `space_before`; the format panel in Keynote and Slides), not empty paragraphs.
- No more than about 6 bullets on a slide; split rather than shrink the font.
- The title is the takeaway ("Checkout errors down 40% after the retry fix"), not a topic ("Results").
- Render to images and look at them. Text overflow is the usual failure.

### Word, Google Docs, Claude Docs

- Use real list styles (List Bullet, List Bullet 2) and heading styles. Never use manual tabs or spaces.
- Paragraph spacing via style "space before", not blank lines.
- Color via heading styles, not hand-colored runs, so it stays consistent.

### Email, chat (Slack), terminal, plain text

- No color and often no markup, so use indentation, blank lines and markers.
- One blank line between groups; indent sub-points with two spaces and "–".
- Lead word in CAPS or bold to mark a group. Bold is `*bold*` in Slack, `**bold**` in most Markdown clients.
- Keep lines short enough not to wrap in the target client.
- In messages meant for pasting, use plain paragraphs and lists; no blockquote markup.

## Check before handing over

- Any element with more than one sentence? Split it.
- Squint at the rendered output (screenshot, PDF page, slide image, preview), not the source. Can you tell a heading from a bullet from a sub-point without reading?
- Grayscale or plain-text version still readable?
- Is every quote and number findable in under two seconds?
