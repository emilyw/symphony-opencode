---
name: linear-comment-media
description:
  Upload validated success media (screenshots/videos) to a Linear issue
  comment using Linear's two-step upload process. First calls fileUpload
  mutation to get a pre-signed URL, then PUTs the file content, and finally
  creates a comment with the asset URL embedded.
---

# Linear Comment Media

Upload launch-validation evidence to a Linear issue and maintain a single
updatable validation comment.

## Prerequisites

- Linear API token with appropriate permissions
- `LINEAR_API_TOKEN` environment variable or `--linear-api-token` argument
- Either `LINEAR_ISSUE_KEY` environment variable or `--issue-key` argument

## Usage

```sh
linear-comment-media [options]
```

### Options

- `--artifact-dir <path>` — Directory containing launch artifacts
  (default: `./test-results/`)
- `--launch-result <path>` — Path to `launch-output.json` from `launch-app`
  (default: `.launch-output.json`)
- `--linear-api-token <token>` — Linear API token (or set
  `LINEAR_API_TOKEN` env var)
- `--issue-key <key>` — Linear issue key (e.g., `EMS-22`) (or set
  `LINEAR_ISSUE_KEY` env var)
- `--screenshot <path>` — Optional path to specific screenshot file
- `--video <path>` — Optional path to specific video file
- `--include-failure-media` — Allow uploading failure diagnostic media
- `--comment-id <id>` — Existing comment ID to update

## Exit Codes

- `0` — Upload completed (status: `uploaded`)
- `0` — Skipped (status: `skipped`, reason in output JSON)
- `1` — Error (message in output JSON)

## Output Contract (JSON to stdout)

```json
{
  "status": "uploaded" | "skipped",
  "issue_key": "EMS-22",
  "comment_url": "https://linear.app/...",
  "uploaded_media": ["https://uploads.linear.app/..."],
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

- Confirm Linear API token is available
- Confirm issue key is available
- Confirm artifact files exist in `--artifact-dir`
- Confirm artifacts are valid media (`.mp4`, `.png`, `.jpg`, `.jpeg`, `.webm`)
- Reject local traces/logs unless `--include-failure-media` is passed

### 3. Upload media (Two-Step Process)

Step 1: Call `fileUpload` GraphQL mutation to get pre-signed upload URL:

```graphql
mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
  fileUpload(filename: $filename, contentType: $contentType, size: $size) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers { key value }
    }
  }
}
```

Step 2: PUT the file content to the `uploadUrl` with the provided headers:

```bash
curl -X PUT "<uploadUrl>" \
  -H "Content-Type: <contentType>" \
  -H "x-goog-content-length-range: <size>,<size>" \
  --data-binary @<file>
```

Step 3: Use the returned `assetUrl` in the comment body

### 4. Find or Create Comment

- If `--comment-id` provided, update that comment
- Otherwise, look for existing comment with marker `<!-- linear-comment-media -->`
- Create new comment if not found

### 5. Output

- Write JSON result to stdout
- `status: uploaded` — media was uploaded and comment updated
- `status: skipped` — upload was skipped (with `skipped_reason`)

## Integration with launch-app

When `linear-comment-media` is called after a successful launch-app run:

1. `launch-app` writes `launch-output.json` with status, artifacts, and validated flow
2. `linear-comment-media` reads this file and uploads media to the specified issue
3. The comment includes all validation evidence (screenshots, video URLs)

## Implementation Notes

- Artifacts are stored in `./test-results/` within the project directory
- This folder should be added to `.gitignore`
- Video uploads use Linear's two-step pre-signed URL process
- Images are uploaded via the same process but marked as `makePublic: true`
- All media is uploaded to Linear's Google Cloud Storage