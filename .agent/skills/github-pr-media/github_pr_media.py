#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


SUCCESS_MEDIA_EXTENSIONS = {".mp4", ".png", ".jpg", ".jpeg", ".webm"}
FAILURE_MEDIA_EXTENSIONS = {".log", ".txt", ".json", ".trace"}
COMMENT_MARKER = "<!-- github-pr-media -->"
SKIPPED_REASONS = {
    "launch_failed": "Launch result status is not success and --include-failure-media was not set",
    "no_pr": "PR not found",
    "no_artifacts": "No artifact files found",
    "no_valid_media": "No valid success media files found",
    "upload_failed": "Failed to upload media to PR",
    "comment_failed": "Failed to create or update PR comment",
}


def run(*args, check=True, capture_output=True, text=True, **kwargs):
    result = subprocess.run(
        ["gh", *args],
        check=check,
        capture_output=capture_output,
        text=text,
        **kwargs,
    )
    return result


def parse_args():
    parser = argparse.ArgumentParser(description="Upload validation media to GitHub PR")
    parser.add_argument("--pr-url", required=True, help="Full GitHub PR URL")
    parser.add_argument(
        "--artifact-dir",
        default=".github/media/",
        help="Directory containing launch artifacts (default: .github/media/)",
    )
    parser.add_argument(
        "--launch-result",
        default=".launch-output.json",
        help="Path to launch-app output JSON (default: .launch-output.json)",
    )
    parser.add_argument(
        "--include-failure-media",
        action="store_true",
        help="Allow uploading failure diagnostic media",
    )
    parser.add_argument(
        "--comment-id",
        help="Existing PR comment ID to update",
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


def extract_repo_and_number_from_pr_url(pr_url: str) -> Optional[tuple[str, str]]:
    match = re.match(r"https://github\.com/([^/]+)/([^/]+)/pull/(\d+)", pr_url)
    if match:
        return f"{match.group(1)}/{match.group(2)}", match.group(3)
    return None


def check_pr_exists(pr_url: str, repo: str) -> tuple[bool, Optional[dict]]:
    try:
        result = run(
            "pr", "view", pr_url,
            "--json", "number,title,url,headRefName,body",
        )
        pr_data = json.loads(result.stdout)
        return True, pr_data
    except subprocess.CalledProcessError:
        return False, None


def find_media_files(artifact_dir: str, include_failure_media: bool):
    path = Path(artifact_dir)
    if not path.is_dir():
        return []

    files = []
    for f in sorted(path.iterdir()):
        if f.is_file():
            ext = f.suffix.lower()
            if ext in SUCCESS_MEDIA_EXTENSIONS:
                files.append(f)
            elif ext in FAILURE_MEDIA_EXTENSIONS and include_failure_media:
                files.append(f)
    return files


def upload_media_via_api(file_path: Path, repo: str, pr_number: str) -> tuple[bool, Optional[str]]:
    upload_url = f"https://uploads.github.com/repos/{repo}/pulls/{pr_number}/assets"

    content_type_map = {
        ".mp4": "video/mp4",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webm": "video/webm",
    }
    content_type = content_type_map.get(file_path.suffix.lower(), "application/octet-stream")

    file_size = os.path.getsize(file_path)

    try:
        with open(file_path, "rb") as f:
            file_content = f.read()

        result = subprocess.run(
            [
                "gh", "api", "--method", "POST",
                "-H", f"Content-Type: {content_type}",
                "-H", f"Content-Length: {file_size}",
                "--input", "-",
                upload_url,
            ],
            input=file_content,
            capture_output=True,
            text=False,
        )

        if result.returncode != 0:
            return False, result.stderr.decode() if result.stderr else "upload failed"

        response_data = json.loads(result.stdout)
        browser_download_url = response_data.get("browser_download_url")
        return True, browser_download_url
    except Exception as e:
        return False, str(e)


def find_existing_media_comment(repo: str, pr_number: str) -> Optional[str]:
    try:
        result = run(
            "api", f"repos/{repo}/pulls/{pr_number}/comments",
        )
        comments = json.loads(result.stdout)
        for comment in comments:
            if COMMENT_MARKER in comment.get("body", ""):
                return comment["id"]
        return None
    except subprocess.CalledProcessError:
        return None


def create_or_update_comment(
    repo: str,
    pr_number: str,
    comment_id: Optional[str],
    comment_body: str,
) -> tuple[bool, Optional[str]]:
    if comment_id:
        return update_comment(repo, pr_number, comment_id, comment_body)
    return create_comment(repo, pr_number, comment_body)


def update_comment(repo: str, pr_number: str, comment_id: str, body: str) -> tuple[bool, Optional[str]]:
    try:
        run(
            "api", f"repos/{repo}/pulls/comments/{comment_id}",
            method="PATCH",
            body=json.dumps({"body": body}),
            headers={"Content-Type": "application/json"},
        )
        comment_url = f"https://github.com/{repo}/pull/{pr_number}#discussion_{comment_id}"
        return True, comment_url
    except subprocess.CalledProcessError as e:
        return False, str(e)


def create_comment(repo: str, pr_number: str, body: str) -> tuple[bool, Optional[str]]:
    try:
        result = run(
            "api", f"repos/{repo}/pulls/{pr_number}/comments",
            method="POST",
            body=json.dumps({"body": body}),
            headers={"Content-Type": "application/json"},
        )
        comment_data = json.loads(result.stdout)
        comment_id = comment_data.get("id")
        comment_url = f"https://github.com/{repo}/pull/{pr_number}#discussion_{comment_id}"
        return True, comment_url
    except subprocess.CalledProcessError as e:
        return False, str(e)


def build_comment_body(
    launch_result: dict,
    pr_data: dict,
    uploaded_media: list[str],
    commit_sha: str,
) -> str:
    tested_url = launch_result.get("url", "N/A")
    screen_flow = launch_result.get("screen_flow", launch_result.get("screenFlow", "N/A"))
    command = launch_result.get("command", launch_result.get("cmd", "N/A"))
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    media_links = "\n".join(f"- {url}" for url in uploaded_media) if uploaded_media else "- (none)"

    body = f"""{COMMENT_MARKER}
## Validation Media

| Field | Value |
|-------|-------|
| **Tested URL** | {tested_url} |
| **Screen Flow** | {screen_flow} |
| **Command** | `{command}` |
| **Commit SHA** | `{commit_sha}` |
| **Timestamp** | {timestamp} |

### Uploaded Media

{media_links}

_Captured automatically by github-pr-media skill._
"""
    return body


def get_commit_sha() -> str:
    try:
        result = run("rev-parse", "HEAD")
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return "unknown"


def output_result(
    status: str,
    pr_url: str,
    comment_url: Optional[str],
    uploaded_media: list[str],
    skipped_reason: Optional[str] = None,
):
    result = {
        "status": status,
        "pr_url": pr_url,
        "comment_url": comment_url,
        "uploaded_media": uploaded_media,
        "skipped_reason": skipped_reason,
    }
    print(json.dumps(result, indent=2))


def main():
    args = parse_args()

    launch_result = read_launch_result(args.launch_result)
    if launch_result is None:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=f"Launch result file not found: {args.launch_result}",
        )
        sys.exit(0)

    ok, reason = check_launch_status(launch_result, args.include_failure_media)
    if not ok:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=reason,
        )
        sys.exit(0)

    repo_number = extract_repo_and_number_from_pr_url(args.pr_url)
    if not repo_number:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_pr"],
        )
        sys.exit(0)

    repo, pr_number = repo_number

    pr_exists, pr_data = check_pr_exists(args.pr_url, repo)
    if not pr_exists or pr_data is None:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_pr"],
        )
        sys.exit(0)

    media_files = find_media_files(args.artifact_dir, args.include_failure_media)
    if not media_files:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=[],
            skipped_reason=SKIPPED_REASONS["no_valid_media"],
        )
        sys.exit(0)

    uploaded_urls = []
    for media_file in media_files:
        ok, url = upload_media_via_api(media_file, repo, pr_number)
        if ok and url:
            uploaded_urls.append(url)
        elif not ok:
            output_result(
                status="skipped",
                pr_url=args.pr_url,
                comment_url=None,
                uploaded_media=uploaded_urls,
                skipped_reason=SKIPPED_REASONS["upload_failed"],
            )
            sys.exit(0)

    comment_id = args.comment_id
    if not comment_id:
        comment_id = find_existing_media_comment(repo, pr_number)

    commit_sha = get_commit_sha()
    comment_body = build_comment_body(launch_result, pr_data, uploaded_urls, commit_sha)

    ok, comment_url = create_or_update_comment(repo, pr_number, comment_id, comment_body)
    if not ok:
        output_result(
            status="skipped",
            pr_url=args.pr_url,
            comment_url=None,
            uploaded_media=uploaded_urls,
            skipped_reason=SKIPPED_REASONS["comment_failed"],
        )
        sys.exit(0)

    output_result(
        status="uploaded",
        pr_url=args.pr_url,
        comment_url=comment_url,
        uploaded_media=uploaded_urls,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()