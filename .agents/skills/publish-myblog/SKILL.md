---
name: publish-myblog
description: Prepare, inspect, preview, check, and publish Ulysses-authored MyBlog posts from TextBundle exports in .myblog/inbox. Use when a user asks Codex to publish, prepare, preview, or validate a named or recently written Ulysses article for MyBlog, including requests such as "發布 Ulysses 的〈文章標題〉到 MyBlog", "把今天在 Ulysses 寫的那篇發布", or "先預覽〈文章標題〉的 MyBlog 發布結果".
---

# Publish MyBlog

Coordinate article selection, metadata review, deterministic validation, and guarded publication. Delegate all Markdown conversion, Jekyll checks, file creation, commit, and push operations to `tools/myblog`; do not reimplement them.

## Enforce the policy

- Accept only user-exported `.textbundle` directories under `<repo>/.myblog/inbox/`. Do not read or modify the Ulysses private library database.
- Treat the first request to publish as intent to prepare. Never treat it as the final authorization to commit or push.
- Run `preview` and `check`, present the complete review summary, and then obtain a new explicit confirmation containing a clear instruction such as `發布` or `確認發布`.
- Never modify article prose. Suggest tags, summary, slug, cover, or structural fixes, but edit even non-prose Markdown only after explicit approval.
- Support published posts only in v1. Stop if the user asks for a draft.
- Preserve image bytes and EXIF. Do not compress, convert, download, or delete images. Keep the existing `tools/myblog` rule that uses the first local image as the cover.
- Select categories only from `allowed_categories` reported by the inspector. Never invent a category.
- On a repeat or possible repeat, stop and ask whether the user intends to update the existing post or create a distinct new post. v1 performs neither automatically and never overwrites.
- Stop on dirty worktrees, detached HEAD, a branch other than `main`, stale local `main`, ambiguous articles, duplicate destinations, or unverifiable remote state.
- Never invoke `tools/myblog-publish-macos`; it is a non-interactive legacy wrapper and cannot provide this skill's two-phase approval.

## Locate the export

Resolve the repository with `git rev-parse --show-toplevel`. Use `.myblog/inbox` below that root. If it does not exist, ask the user to create it or create it only with permission.

Ask the user to export one Ulysses sheet as TextBundle into `.myblog/inbox/` when no usable candidate exists. Do not rely on a Ulysses share extension, Shortcuts shell action, UI scraping, or direct database access.

Run the bundled inspector before asking for metadata:

```bash
ruby .agents/skills/publish-myblog/scripts/inspect_inbox.rb inspect --repo "$repo_root" --title "ARTICLE TITLE"
```

Omit `--title` to list all candidates. For "today's article", add `--modified-on YYYY-MM-DD`, using the user's local date. Interpret selection as follows:

1. Require one exact normalized H1-title match when a title was supplied.
2. If zero candidates match, show the available titles and request a corrected title or a new export.
3. If multiple candidates match, show title, relative path, modified time, and the first 12 hash characters; ask the user to select one.
4. Never select by newest modification time when more than one candidate remains.
5. Treat `content_sha256` plus the source path as the stable export identity. Use `receipts` and `existing_posts` to detect retries.

## Review content and metadata

Treat these inspector findings as blockers:

- parse errors or a missing first H1/first text paragraph;
- symlinks, missing local images, or asset paths outside `assets/`;
- normalized filename collisions;
- empty image alt text;
- an H1 remaining in the body;
- an existing post or receipt indicating a retry.

Treat remote images, unsupported image paths, duplicate image bytes, unreferenced assets, and heading-level jumps as warnings that require an explicit resolution before publication. Do not silently download a remote image or discard an asset.

Gather only missing metadata:

- `category`: require one value from `allowed_categories`; suggest but confirm it.
- `tags`: optional; suggest a short set based on the article, but accept an empty set.
- `date`: default to the user's current local date, show it in the review, and accept an explicit `YYYY-MM-DD` override.
- `title`, `description`, `slug`, and cover: derive them with `tools/myblog`. Report the generated values; do not hand-edit them because publish must reproduce preview exactly.

Pass tags as one comma-separated argument. Quote every path and metadata argument. Do not interpolate article content into an executable shell fragment.

## Prepare without writing

Run both existing commands with identical metadata:

```bash
ruby tools/myblog preview "BUNDLE_PATH" --category "CATEGORY" --tags "TAG1,TAG2" --date YYYY-MM-DD
ruby tools/myblog check "BUNDLE_PATH" --category "CATEGORY" --tags "TAG1,TAG2" --date YYYY-MM-DD
```

Both commands must complete successfully. `preview` prints the exact generated post; `check` builds and tests a temporary production site without creating a post, commit, or push in the repository.

Then show one review summary containing:

- selected source path, title, 12-character content hash, and modified time;
- planned `_posts` path, asset count and mappings, category, tags, date, description, cover, and public URL;
- every blocker and warning, including alt-text and remote-image status;
- `preview` and `check` results;
- `git status --short --branch`, `git diff --check`, `git diff --stat`, and the relevant textual diff if the worktree is not clean.

Do not proceed while any blocker or unresolved warning remains. End the preparation phase by asking for a fresh explicit publish confirmation.

## Publish only after confirmation

After the fresh confirmation, re-run the inspector and `check`; do not reuse stale results. Require the content hash and metadata to match the reviewed values.

Immediately before publishing:

1. Require `git branch --show-current` to equal `main`.
2. Require `git status --porcelain --untracked-files=all` to be empty.
3. Read `HEAD` with `git rev-parse HEAD`.
4. Read the live remote SHA with `git ls-remote --exit-code origin refs/heads/main` and require it to equal `HEAD`. A cached `origin/main` value is insufficient.
5. Reconfirm that the planned post and asset destination do not exist.

Invoke the existing publisher exactly once:

```bash
ruby tools/myblog publish "BUNDLE_PATH" --category "CATEGORY" --tags "TAG1,TAG2" --date YYYY-MM-DD
```

If it fails, do not automatically retry. Report the command stage, current Git status, current `HEAD`, created post/assets if any, and a recoverable next action. Never delete or reset generated work automatically.

## Verify publication

Do not trust success output alone. After `publish` returns:

1. Require `HEAD` to differ from the pre-publish SHA.
2. Inspect `git show --stat --oneline HEAD` and `git diff-tree --no-commit-id --name-only -r HEAD`; require the commit to contain only the reviewed post and its asset directory.
3. Query `git ls-remote --exit-code origin refs/heads/main` again and require its SHA to equal the new `HEAD`.
4. If `gh auth status` succeeds, run `gh run list --workflow pages-deploy.yml --commit "COMMIT_SHA" --limit 1 --json databaseId,status,conclusion,url`, wait briefly for a run to appear, and then run `gh run watch "RUN_ID" --exit-status`. If `gh` is unavailable or no run appears within a bounded wait, say that CI was not verified rather than assuming success.
5. After deployment succeeds, fetch the public URL with `curl --fail --location --silent --show-error "PUBLIC_URL"` and require the response to contain the article title. If deployment is still running, report that state and do not claim the site is live.
6. Record a local idempotency receipt only after commit and remote verification:

```bash
ruby .agents/skills/publish-myblog/scripts/inspect_inbox.rb record --repo "$repo_root" --bundle "BUNDLE_PATH" --post "POST_PATH" --commit "COMMIT_SHA" --url "PUBLIC_URL"
```

Report the final post path, image count, commit SHA, remote verification, deployment result, and public URL verification.
