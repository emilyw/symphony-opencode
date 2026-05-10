---
name: github-pr-media
description:
  Upload validated success media (screenshots/videos) to a GitHub PR and update
  a single validation comment. Use when app-touching work requires visible PR
  evidence of successful runtime validation.
---

# GitHub PR Media

Upload launch-validation evidence to a GitHub PR and maintain a single
updatable validation comment.

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status` passes)
- GitHub remote must be `origin`
- Workspace must be a valid git working tree (for commit SHA detection)

## Usage

```sh
github-pr-media --pr-url <url> [options]
```

### Required Arguments

- `--pr-url <url>` — Full GitHub PR URL (e.g.
  `https://github.com/owner/repo/pull/123`)

### Options

- `--artifact-dir <path>` — Directory containing launch artifacts (default:
  `.github/media/`)
- `--launch-result <path>` — Path to `launch-output.json` from `launch-app`
  (default: `.launch-output.json`)
- `--include-failure-media` — Allow uploading failure diagnostic media when
  launch result status is not `success`
- `--comment-id <id>` — Existing PR comment ID to update (instead of creating
  a new one)

## Exit Codes

- `0` — Upload completed (status: `uploaded`)
- `0` — Skipped (status: `skipped`, reason in output JSON)
- `1` — Error (message in output JSON)

## Output Contract (JSON to stdout)

```json
{
  "status": "uploaded" | "skipped",
  "pr_url": "<pr-url>",
  "comment_url": "<comment-url>",
  "uploaded_media": [""],
  "skipped_reason": "<reason>" | null
}
```

## Behavior

### 1. Accept launch result

- Read `launch-output.json` (or path given by `--launch-result`)
- Require `status: success` in the JSON
- Refuse upload if status is not `success` unless `--include-failure-media`
  is set

### 2. Validate inputs

- Confirm the PR exists via `gh pr view`
- Confirm artifact files exist in `--artifact-dir`
- Confirm artifacts are success media (`.mp4`, `.png`, `.jpg`, `.webm`)
- Reject local traces/logs (`.log`, `.txt`, `.json`) unless
  `--include-failure-media` is set

### 3. Upload media

- Upload each confirmed media file to the PR via `gh pr upload`
- Produce stable PR-visible links
- Skip uploading logs/traces unless `--include-failure-media` is passed

### 4. Update PR comment

- Find or create **one** validation comment
- If `--comment-id` is provided, update that comment
- Otherwise, search for an existing comment by this bot with the marker
  `<!-- github-pr-media -->`; update it, or create one if not found
- Comment content includes:
  - tested URL (from launch result)
  - validated screen flow
  - command summary
  - screenshot/video links
  - timestamp and commit SHA
- Avoid duplicate comments on repeated runs

### 5. Output

- Write JSON result to stdout
- `status: uploaded` — media was uploaded and comment updated
- `status: skipped` — upload was skipped (with `skipped_reason`)