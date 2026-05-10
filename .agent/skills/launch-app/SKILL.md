---
name: launch-app
description:
  Start an app, validate the changed screen flow, and produce local evidence.
  On success, uploads media to Linear via linear-comment-media skill.
---

# Launch App

## Purpose

Start the app, validate the changed screen flow, and produce local evidence.
On successful validation, uploads media to Linear via the linear-comment-media skill.

## Workflow

### Step 1: Detect Runtime

1. Identify the app type by checking:
   - File extensions (`.js`, `.ts`, `.tsx`, `.py`, `.rb`, etc.)
   - Package manager files (`package.json`, `Pipfile`, `Gemfile`, `go.mod`, etc.)
   - Framework indicators (`next.config.js`, `vite.config.ts`, `webpack.config.js`, etc.)

2. Determine the start command:
   - Check `package.json` scripts (`dev`, `start`, `serve`)
   - Check for common start commands in project config
   - Check for Makefile or other build tools

3. Determine the expected port/URL:
   - Check common port conventions (3000 for Next.js, 5173 for Vite, 8000 for Django, etc.)
   - Check project config for explicit port settings
   - Default to `localhost` with detected or common port

4. Check for project-specific config:
   - Look for `.env`, `.env.local`, `config.js`, etc.
   - Respect any `PORT`, `HOST`, `BASE_URL` environment variables

5. Detect port conflicts:
   - Check if expected port is already in use using `lsof` or `netstat`
   - If conflict detected, report it and optionally try alternative ports

### Step 2: Start App

1. Run the app command in the background:
   ```bash
   cd /path/to/project && <start_command> > /tmp/app_server.log 2>&1 &
   echo $! > /tmp/app_server.pid
   ```

2. Wait for the server to be ready:
   - Poll the health endpoint if available
   - Or check for specific patterns in the server log
   - Or wait a reasonable timeout (30-60 seconds depending on app type)

3. Fail early if the app cannot start:
   - Check if the process is still running
   - Check server logs for fatal errors
   - If failed, capture diagnostics and report failure

### Step 3: Run First Validation Pass (Without Video)

1. Set up Playwright if not already installed:
   ```bash
   npm install -D playwright @playwright/test
   npx playwright install --with-deps chromium
   ```

2. Create a Playwright test script that:
   - Navigates through the changed screen flow
   - Runs the required assertions for the ticket/test plan
   - Captures lightweight diagnostics:
     - Screenshot on failure
     - Console errors
     - Page errors
     - Failed network requests
     - Server log tail
   - Optionally enable Playwright trace on failure

3. Run the Playwright test WITHOUT video recording:
   ```bash
   npx playwright test --reporter=line
   ```

### Step 4: Handle Failure

If validation fails:

1. Do NOT record or upload video
2. Keep local diagnostics only
3. Print a concise failure summary:
   - Failed step
   - URL at failure
   - Assertion/error details
   - Local artifact paths (screenshots, traces, logs)
4. If failure is unclear and needs live inspection, escalate to Chrome DevTools MCP

### Step 5: Handle Success

If validation passes:

1. Re-run the same validated flow WITH recording enabled:
   ```bash
   npx playwright test --reporter=line --video=on
   ```

2. Capture clean success media:
    - Video recording
    - Final screenshot
    - Optional trace

3. Write `launch-output.json` with validation results

4. Invoke `linear-comment-media` skill to upload media to Linear:
   ```bash
   linear-comment-media --launch-result launch-output.json
   ```

5. Return local artifact paths and validation summary

### Step 6: Output Contract

The skill returns a structured result:

```json
{
  "status": "success" | "failure",
  "app_url": "http://localhost:3000",
  "commands_run": ["npm run dev", "npx playwright test"],
  "validated_flow": ["visit home", "click login", "submit form"],
  "artifacts": {
    "screenshot": "/tmp/playwright/screenshots/failure.png",
    "video": "/tmp/playwright/videos/success.webm",
    "trace": "/tmp/playwright/traces/trace.zip"
  },
  "console_errors": [],
  "network_failures": [],
  "server_log_tail": "...",
  "debug_recommendation": "..." // only if failed
}
```

## Implementation Notes

- All artifacts remain local in `./test-results/` within the project directory
- This folder should be added to `.gitignore`
- On success, media is uploaded to Linear via `linear-comment-media` skill
- Port detection should handle common conflicts gracefully
- The skill should work with any Playwright-supported browser (chromium by default)
- Server logs should be captured to temporary files for tailing

## Configuration

The skill can respect project-specific configuration if present:
- `.playwright.config.ts` or `playwright.config.js` for Playwright settings
- `.env` files for app environment variables
- Project-specific package manager scripts