---
name: organize-files
description: "Organize a folder of files by surveying contents, grouping by type, and presenting a numbered list for user decisions. Use when asked to go through, triage, or organize a folder of files."
---

# File Organizer

You are helping the user triage and organize a folder of files. Your role is to survey the contents, understand what each file is, group similar items, and present clear numbered decisions for the user to act on efficiently.

## What You Do

- Survey a target folder and understand what each file is
- Convert `.docx`/`.doc`/`.odt` files to markdown using pandoc, moving originals to `~/Documents/converted/`
- Group files by type and purpose
- Present numbered lists with descriptions and suggested destinations
- Execute moves, renames, and deletions based on user responses
- Update `vault-structure.md` (in `${XDG_CONFIG_HOME:-~/.config}/organize-files/`) after each batch to record new destinations and patterns
- Repeat until the folder is clear

## What You Don't Do

- Move or delete files without user approval
- Put sensitive files (credentials, private keys) in the Obsidian vault
- Force binary or data files (zip archives, CSVs, executables) into the vault unless meaningful
- Process subfolders without explicit direction — handle one level at a time

## CRITICAL: Numbered List Format

Always present files as a numbered list, one per number, with:
- A short description of what the file actually contains (peek first if needed)
- A suggested destination

**Example:**
```
1. `MyValues.md` — personal values list → `Reference/`
2. `Invoice-2024.pdf` — client invoice → `Pine Peak Digital/Invoices/`
3. `temp.txt` — empty file → Delete?
```

The user responds with numbers and actions:
- `1 y` — accept the suggestion
- `2 Pine Peak Digital/Beeminder` — use a different destination
- `3 del` — delete the file

## Workflow

### Step 1: Survey

List the target folder and identify file types and purposes. Peek at text files you're unsure about:

```bash
ls ~/Downloads/Inbox/Inbox/
head -20 ~/Downloads/Inbox/Inbox/mystery-file.md
```

### Step 2: Convert Documents

Before triaging, convert all `.docx`, `.doc` (if supported), and `.odt` files to markdown. Move originals to `~/Documents/converted/`:

```bash
mkdir -p ~/Documents/converted
cd /target/folder
for f in *.docx *.odt; do
  [ -f "$f" ] || continue
  base="${f%.*}"
  pandoc "$f" -o "${base}.md" && mv "$f" ~/Documents/converted/
done
```

Note: pandoc cannot convert old `.doc` files — leave those in place and flag them.

### Step 3: Group and Present

Group files by category (work docs, personal docs, financial data, media, etc.) and present numbered lists. Keep groups to ~10 items for readability.

### Step 4: Execute

After user responses, execute all moves and deletes in a single bash command per batch:

```bash
cd /target/folder
mv "file1.md" "/destination/path/"
rm "file2.md"
mkdir -p "/new/folder" && mv "file3.pdf" "/new/folder/"
```

### Step 5: Update vault-structure.md

After executing each batch, update `${XDG_CONFIG_HOME:-~/.config}/organize-files/vault-structure.md` to record:
- Any new folders created that aren't already listed
- Any new destination patterns or content-type mappings learned
- Any corrections the user made to your suggestions (e.g. "not Scans/, use Reference/Taxes/")
- Any new "Patterns & Lessons" entries from what the user deleted or redirected

Do this by reading the file, then editing it in place. Do not duplicate existing entries.

### Step 6: Repeat

Show remaining files and continue until the folder is empty or the user is done.

## Obsidian Vault Structure

**Always read `${XDG_CONFIG_HOME:-~/.config}/organize-files/vault-structure.md` at the start of a session** — it contains the full, up-to-date folder map and filing patterns learned from past sessions.

Key rules from that file:
- **`Scans/` is NOT a valid destination** — it is the physical scanner's inbox. Use `Reference/Taxes/`, `Reference/Bills/`, etc. instead.
- See `vault-structure.md` for the full folder list and patterns.

## Tips

- Raw data exports (CSV time tracking, YNAB exports, survey data) are rarely vault-worthy — suggest delete unless the user has a reason to keep them
- Untitled files should be peeked at before suggesting delete
- Duplicate files (e.g., `file.docx` and `Copy of file.docx`) — suggest deleting the copy after converting
- macOS `._` sidecar files and `.DS_Store` — always delete
- Large binary files (DMGs, executables, video) don't belong in the vault
- When creating new subfolders, check if a similar one already exists first
