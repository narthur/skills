---
name: surge-image-upload
description: >
  Upload local image(s) to a public surge.sh URL and embed them in GitHub
  PRs/issues or any markdown — no browser required. Fallback only: for GitHub
  issue/PR bodies and comments, `gh --attach` (gh >= 2.99) uploads images and
  videos directly, so use this skill only when that is unavailable (GHES, a
  GitHub App/Actions token, which the upload endpoint rejects) or when the URL
  is needed outside GitHub. No browser or login required; surge URLs render inline on public
  repos via GitHub's image proxy.
---

# Surge Image Upload

Publish local images to a stable [surge.sh](https://surge.sh) static site and
get back public `https://<domain>/<hash>.<ext>` URLs that render inline in
GitHub markdown (PRs, issues, comments) and anywhere else.

## How It Works

A single persistent **uploads folder** is the source of truth. `upload.sh`:

1. Content-addresses each image (`sha256` prefix → `ab12cd34ef56.png`), so the
   same bytes always map to the same URL (idempotent) and different images never
   collide.
2. Copies it into the uploads folder.
3. Mirrors the **whole folder** to one surge domain.

Because the folder accumulates, previously-uploaded images keep working across
runs — as long as the folder is kept. Nothing is committed to any git repo and
no browser/login dance is needed.

## Prerequisites

- `surge` CLI on `PATH` (pnpm/npm global). Install: `pnpm add -g surge`.
- Logged in once: `surge login` (token is stored in `~/.netrc`). Check with
  `surge whoami`. The script fails fast with a clear message if either is missing.

## Usage

```bash
~/.claude/skills/surge-image-upload/upload.sh <image> [image...]
```

Prints one public URL per input file to **stdout** (surge's own output goes to
stderr, so stdout stays pipe-clean):

```
https://narthur-uploads.surge.sh/ab12cd34ef56.png
https://narthur-uploads.surge.sh/99aa88bb77cc.png
```

### Embed in a GitHub PR/issue

```bash
url=$(~/.claude/skills/surge-image-upload/upload.sh shot.png)
gh pr comment <number> --body "![screenshot]($url)"
# or fold into a PR body / issue with gh pr edit / gh issue edit
```

## Configuration (env, optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `SURGE_UPLOAD_DIR` | `${XDG_DATA_HOME:-~/.local/share}/surge-uploads` | Persistent uploads folder |
| `SURGE_UPLOAD_DOMAIN` | value in `<dir>/CNAME`, else `narthur-uploads.surge.sh` | Surge domain to publish to |

The chosen domain is persisted to `<dir>/CNAME`, so the first run pins it and
later runs reuse it. To move to a new domain, set `SURGE_UPLOAD_DOMAIN` (or edit
the `CNAME` file) and re-run.

## Notes

- **Public hosting.** Anyone with the URL (and anyone browsing the surge domain)
  can see uploaded images. Don't upload anything sensitive.
- **Persistence.** Images live as long as the uploads folder + surge site exist.
  Deleting a file from the folder and re-deploying removes it from the site.
- **Private repos.** GitHub's image proxy still fetches public surge URLs, so
  embeds render regardless of repo visibility — but the image itself is public.
- The image is public. For a private repo where that matters, attach the file
  through the GitHub web UI by hand instead — there is no scripted path here.
