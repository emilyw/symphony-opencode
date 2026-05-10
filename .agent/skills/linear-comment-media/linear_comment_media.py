#!/usr/bin/env python3
"""
Linear Comment Media Upload

Upload validation media to Linear issue comments using the two-step upload process:
1. Call fileUpload mutation to get a pre-signed GCS URL
2. PUT the file content to that URL
3. Create/update comment with the asset URL
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

LINEAR_API_URL = "https://api.linear.app/graphql"
LINEAR_COMMENT_MARKER = "<!-- linear-comment-media -->"

SUCCESS_MEDIA_EXTENSIONS = {".mp4", ".png", ".jpg", ".jpeg", ".webm"}
FAILURE_MEDIA_EXTENSIONS = {".log", ".txt", ".json", ".trace"}

SKIPPED_REASONS = {
    "launch_failed": "Launch result status is not success and --include-failure-media was not set",
    "no_token": "Linear API token not provided (set LINEAR_API_TOKEN env var or --linear-api-token)",
    "no_issue_key": "Issue key not provided (set LINEAR_ISSUE_KEY env var or --issue-key)",
    "no_artifacts": "No artifact files found",
    "no_valid_media": "No valid success media files found",
    "upload_failed": "Failed to upload media to Linear",
    "comment_failed": "Failed to create or update Linear comment",
    "issue_not_found": "Could not find Linear issue",
}


def run_graphql(query: str, variables: dict, api_token: str) -> Optional[dict]:
    """Execute a GraphQL query against Linear API."""
    result = subprocess.run(
        ["curl", "-s", "-X", "POST", LINEAR_API_URL,
         "-H", f"Authorization: {api_token}",
         "-H", "Content-Type: application/json",
         "-d", json.dumps({"query": query, "variables": variables})],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout)
    if "errors" in data:
        print(f"GraphQL errors: {data['errors']}", file=sys.stderr)
        return None
    return data.get("data")


def get_issue_id(issue_key: str, api_token: str) -> Optional[str]:
    """Get the internal issue ID from issue key (e.g., EMS-22)."""
    query = """
    query SearchIssues($term: String!) {
        searchIssues(term: $term) {
            nodes {
                id
                identifier
                title
            }
        }
    }
    """
    data = run_graphql(query, {"term": issue_key}, api_token)
    if not data:
        return None
    nodes = data.get("searchIssues", {}).get("nodes", [])
    for node in nodes:
        if node.get("identifier") == issue_key:
            return node.get("id")
    return None


def file_upload(filename: str, content_type: str, file_size: int, api_token: str) -> Optional[dict]:
    """Step 1: Get pre-signed upload URL via fileUpload mutation."""
    query = """
    mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
        fileUpload(filename: $filename, contentType: $contentType, size: $size) {
            success
            uploadFile {
                uploadUrl
                assetUrl
                headers {
                    key
                    value
                }
            }
        }
    }
    """
    data = run_graphql(query, {
        "filename": filename,
        "contentType": content_type,
        "size": file_size
    }, api_token)
    if not data:
        return None
    return data.get("fileUpload")


def upload_to_gcs(upload_url: str, headers: list, file_path: Path, content_type: str) -> bool:
    """Step 2: PUT file content to GCS pre-signed URL."""
    header_dict = {h["key"]: h["value"] for h in headers}

    with open(file_path, "rb") as f:
        file_content = f.read()

    cmd = ["curl", "-s", "-X", "PUT", upload_url]
    for key, value in header_dict.items():
        cmd.extend(["-H", f"{key}: {value}"])
    cmd.extend(["-H", f"Content-Type: {content_type}"])
    cmd.extend(["--data-binary", "@-"])

    result = subprocess.run(
        cmd,
        input=file_content,
        capture_output=True,
    )
    return result.returncode == 0


def create_comment(issue_id: str, body: str, api_token: str) -> Optional[dict]:
    """Create a new comment on a Linear issue."""
    query = """
    mutation CreateComment($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
            success
            comment {
                id
                url
            }
        }
    }
    """
    data = run_graphql(query, {"issueId": issue_id, "body": body}, api_token)
    if not data:
        return None
    return data.get("commentCreate")


def update_comment(comment_id: str, body: str, api_token: str) -> Optional[dict]:
    """Update an existing comment."""
    query = """
    mutation UpdateComment($id: String!, $body: String!) {
        commentUpdate(id: $id, input: { body: $body }) {
            success
            comment {
                id
                url
            }
        }
    }
    """
    data = run_graphql(query, {"id": comment_id, "body": body}, api_token)
    if not data:
        return None
    return data.get("commentUpdate")


def find_existing_comment(issue_id: str, api_token: str) -> Optional[str]:
    """Find existing comment with our marker."""
    query = """
    query GetComments($issueId: String!) {
        issue(id: $issueId) {
            comments {
                nodes {
                    id
                    body
                }
            }
        }
    }
    """
    data = run_graphql(query, {"issueId": issue_id}, api_token)
    if not data:
        return None

    nodes = data.get("issue", {}).get("comments", {}).get("nodes", [])
    for node in nodes:
        if LINEAR_COMMENT_MARKER in node.get("body", ""):
            return node.get("id")
    return None


def build_comment_body(
    launch_result: dict,
    issue_key: str,
    uploaded_media: list[str],
) -> str:
    """Build the comment body with validation details."""
    tested_url = launch_result.get("app_url", launch_result.get("url", "N/A"))
    validated_flow = launch_result.get("validated_flow", [])
    flow_str = " → ".join(validated_flow) if validated_flow else "N/A"
    commands = launch_result.get("commands_run", [])
    commands_str = ", ".join(f"`{c}`" for c in commands) if commands else "N/A"
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    media_section = ""
    for url in uploaded_media:
        ext = Path(url).suffix.lower() if url else ""
        if ext in {".mp4", ".webm"}:
            media_section += f"\n![Video]({url})"
        else:
            media_section += f"\n![Media]({url})"

    body = f"""{LINEAR_COMMENT_MARKER}
## ✅ Launch Validation

| Field | Value |
|-------|-------|
| **Issue** | {issue_key} |
| **Tested URL** | {tested_url} |
| **Validated Flow** | {flow_str} |
| **Commands** | {commands_str} |
| **Timestamp** | {timestamp} |

### Media

{media_section if media_section else "_No media uploaded_"}

_Captured automatically by linear-comment-media skill._
"""
    return body


def parse_args():
    parser = argparse.ArgumentParser(description="Upload validation media to Linear issue")
    parser.add_argument(
        "--artifact-dir",
        default="./test-results/",
        help="Directory containing launch artifacts (default: ./test-results/)",
    )
    parser.add_argument(
        "--launch-result",
        default=".launch-output.json",
        help="Path to launch-app output JSON (default: .launch-output.json)",
    )
    parser.add_argument(
        "--linear-api-token",
        default=os.environ.get("LINEAR_API_TOKEN"),
        help="Linear API token (or set LINEAR_API_TOKEN env var)",
    )
    parser.add_argument(
        "--issue-key",
        default=os.environ.get("LINEAR_ISSUE_KEY"),
        help="Linear issue key like EMS-22 (or set LINEAR_ISSUE_KEY env var)",
    )
    parser.add_argument(
        "--screenshot",
        help="Specific screenshot file path",
    )
    parser.add_argument(
        "--video",
        help="Specific video file path",
    )
    parser.add_argument(
        "--include-failure-media",
        action="store_true",
        help="Allow uploading failure diagnostic media",
    )
    parser.add_argument(
        "--comment-id",
        help="Existing comment ID to update",
    )
    return parser.parse_args()


def read_launch_result(path: str) -> Optional[dict]:
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def check_launch_status(launch_result: dict, include_failure_media: bool) -> tuple[bool, str]:
    status = launch_result.get("status")
    if status == "success":
        return True, ""
    if include_failure_media:
        return True, ""
    return False, SKIPPED_REASONS["launch_failed"]


def find_media_files(artifact_dir: str, include_failure_media: bool, screenshot: str = None, video: str = None):
    """Find media files to upload."""
    files = []

    if screenshot and os.path.exists(screenshot):
        files.append(Path(screenshot))
    if video and os.path.exists(video):
        files.append(Path(video))

    if files:
        return files

    path = Path(artifact_dir)
    if not path.is_dir():
        return []

    for f in sorted(path.rglob("*")):
        if f.is_file():
            ext = f.suffix.lower()
            if ext in SUCCESS_MEDIA_EXTENSIONS:
                files.append(f)
            elif ext in FAILURE_MEDIA_EXTENSIONS and include_failure_media:
                files.append(f)

    return files


def upload_single_file(file_path: Path, api_token: str) -> Optional[str]:
    """Upload a single file using the two-step process."""
    content_type_map = {
        ".mp4": "video/mp4",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webm": "video/webm",
    }
    content_type = content_type_map.get(file_path.suffix.lower(), "application/octet-stream")
    file_size = os.path.getsize(file_path)

    upload_data = file_upload(file_path.name, content_type, file_size, api_token)
    if not upload_data or not upload_data.get("success"):
        print(f"fileUpload failed for {file_path}", file=sys.stderr)
        return None

    upload_file = upload_data.get("uploadFile", {})
    upload_url = upload_file.get("uploadUrl")
    headers = upload_file.get("headers", [])

    if not upload_url:
        print(f"No upload URL returned for {file_path}", file=sys.stderr)
        return None

    success = upload_to_gcs(upload_url, headers, file_path, content_type)
    if not success:
        print(f"GCS upload failed for {file_path}", file=sys.stderr)
        return None

    return upload_file.get("assetUrl")


def output_result(
    status: str,
    issue_key: str,
    comment_url: Optional[str],
    uploaded_media: list[str],
    skipped_reason: Optional[str] = None,
):
    result = {
        "status": status,
        "issue_key": issue_key,
        "comment_url": comment_url,
        "uploaded_media": uploaded_media,
        "skipped_reason": skipped_reason,
    }
    print(json.dumps(result, indent=2))


def main():
    args = parse_args()

    api_token = args.linear_api_token
    if not api_token:
        output_result(
            status="skipped",
            issue_key=args.issue_key or "unknown",
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_token"],
        )
        sys.exit(0)

    issue_key = args.issue_key
    if not issue_key:
        output_result(
            status="skipped",
            issue_key="unknown",
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_issue_key"],
        )
        sys.exit(0)

    launch_result = read_launch_result(args.launch_result)
    if launch_result is None:
        output_result(
            status="skipped",
            issue_key=issue_key,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=f"Launch result file not found: {args.launch_result}",
        )
        sys.exit(0)

    ok, reason = check_launch_status(launch_result, args.include_failure_media)
    if not ok:
        output_result(
            status="skipped",
            issue_key=issue_key,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=reason,
        )
        sys.exit(0)

    issue_id = get_issue_id(issue_key, api_token)
    if not issue_id:
        output_result(
            status="skipped",
            issue_key=issue_key,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["issue_not_found"],
        )
        sys.exit(0)

    media_files = find_media_files(args.artifact_dir, args.include_failure_media, args.screenshot, args.video)
    if not media_files:
        output_result(
            status="skipped",
            issue_key=issue_key,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_valid_media"],
        )
        sys.exit(0)

    uploaded_urls = []
    for media_file in media_files:
        url = upload_single_file(media_file, api_token)
        if url:
            uploaded_urls.append(url)
        else:
            output_result(
                status="skipped",
                issue_key=issue_key,
                comment_url=None,
                uploaded_media=uploaded_urls,
                skipped_reason=SKIPPED_REASONS["upload_failed"],
            )
            sys.exit(0)

    comment_id = args.comment_id
    if not comment_id:
        comment_id = find_existing_comment(issue_id, api_token)

    comment_body = build_comment_body(launch_result, issue_key, uploaded_urls)

    if comment_id:
        result = update_comment(comment_id, comment_body, api_token)
        if not result or not result.get("success"):
            output_result(
                status="skipped",
                issue_key=issue_key,
                comment_url=None,
                uploaded_media=uploaded_urls,
                skipped_reason=SKIPPED_REASONS["comment_failed"],
            )
            sys.exit(0)
        comment_url = result.get("comment", {}).get("url")
    else:
        result = create_comment(issue_id, comment_body, api_token)
        if not result or not result.get("success"):
            output_result(
                status="skipped",
                issue_key=issue_key,
                comment_url=None,
                uploaded_media=uploaded_urls,
                skipped_reason=SKIPPED_REASONS["comment_failed"],
            )
            sys.exit(0)
        comment_url = result.get("comment", {}).get("url")

    output_result(
        status="uploaded",
        issue_key=issue_key,
        comment_url=comment_url,
        uploaded_media=uploaded_urls,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()