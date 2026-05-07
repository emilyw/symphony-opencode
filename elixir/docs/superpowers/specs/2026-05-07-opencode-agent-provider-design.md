# OpenCode Agent Provider Support — Design Spec

**Date:** 2026-05-07
**Status:** Approved

## Goal

Add OpenCode as an alternative agent provider alongside Codex, selected via `agent.provider` config in WORKFLOW.md.

---

## Architecture

Provider-agnostic agent runner. `Config.agent_provider()` returns `:codex` or `:opencode`. `AgentRunner` dispatches to the appropriate protocol module. Both providers share the same session lifecycle, orchestrator retry logic, and workspace management.

```
AgentRunner.run_issue()
  → Config.agent_provider()
  → :codex  → Codex.AppServer.start_session() → do_run_codex_turns()
  → :opencode → Opencode.Server.start_session() → do_run_opencode_turns()
```

---

## Config Schema Changes

### lib/symphony_elixir/config/schema.ex

Add `Opencode` embedded schema alongside existing `Codex`:

```elixir
defmodule Opencode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "opencode")
    field(:port, :integer, default: 7777)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :port, :turn_timeout_ms, :stall_timeout_ms], empty_values: [])
    |> validate_required([:command])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
  end
end
```

Add to main embedded_schema:
```elixir
embeds_one(:opencode, Opencode, on_replace: :update, defaults_to_struct: true)
```

Update `finalize_settings/1` to include `opencode: settings.opencode`.

Update `resolve_turn_sandbox_policy/2` and `resolve_runtime_turn_sandbox_policy/3` to handle Opencode (using same turn_sandbox_policy defaults as Codex when not explicitly set).

### lib/symphony_elixir/config.ex

Add:
- `agent_provider()` — returns `:codex` or `:opencode` based on whether `settings.opencode` is configured
- `opencode_runtime_settings(workspace, opts)` — returns port, command, turn_timeout_ms, stall_timeout_ms
- `agent_runtime_settings(workspace, opts)` — delegates to appropriate provider's runtime settings

Keep existing `codex_runtime_settings/2` for backward compat.

---

## WORKFLOW.md Format

```yaml
agent:
  provider: opencode    # or: codex (default when opencode block absent)
  max_concurrent_agents: 10
  max_turns: 20

opencode:
  command: opencode
  port: 7777
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

codex:
  command: /path/to/codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
```

When `provider: codex` (default), the `codex` block is used and `opencode` block is ignored.
When `provider: opencode`, the `opencode` block is used and `codex` block is ignored.

---

## OpenCode Server Module

### lib/symphony_elixir/opencode/server.ex

New module — HTTP client for OpenCode server mode.

**Lifecycle:**
1. `start_session(workspace, opts)` — validate workspace, check server readiness, create HTTP session
2. `run_turn(session, prompt, issue, opts)` — POST message, stream SSE events, handle tool calls
3. `stop_session(session)` — delete session from server

**Per-issue server model:** One OpenCode server process per workspace (port from config). Matches Codex isolation safety. Port management: use config port + workspace hash for stable port allocation, or ephemeral port with discovery.

**SSE event handling:**
- Stream from `GET /session/:id/events`
- Parse `data: <json>` lines
- Events: `done`, `tool_call`, `error`
- Tool calls routed to `SymphonyElixir.Codex.DynamicTool.execute/2`

**Session type:**
```elixir
@type session :: %{
  port: integer(),
  base_url: String.t(),
  session_id: String.t() | nil,
  workspace: Path.t(),
  worker_host: String.t() | nil,
  turn_timeout_ms: integer(),
  stall_timeout_ms: integer()
}
```

---

## AgentRunner Changes

Rename `run_codex_turns` → `run_agent_turns` with provider dispatch:

```elixir
defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
  case Config.agent_provider() do
    :opencode ->
      with {:ok, session} <- Opencode.Server.start_session(workspace, worker_host: worker_host) do
        try do
          do_run_opencode_turns(session, workspace, issue, agent_update_recipient, opts, ...)
        after
          Opencode.Server.stop_session(session)
        end
      end

    :codex ->
      with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
        try do
          do_run_codex_turns(session, workspace, issue, agent_update_recipient, opts, ...)
        after
          AppServer.stop_session(session)
        end
      end
  end
end
```

Orchestrator message format unchanged — `{:codex_worker_update, issue_id, message}` stays for backward compat with existing orchestrator handlers.

---

## Error Handling

Same orchestrator retry logic (exponential backoff via `@failure_retry_base_ms`). OpenCode turn failures propagate same as Codex failures — orchestrator handles retry decisions.

---

## Backward Compatibility

- `provider: codex` (or absent) → existing Codex behavior unchanged
- Orchestrator message format unchanged
- DynamicTool integration unchanged
- WORKFLOW.md `codex` block unchanged

---

## Files to Modify/Create

| File | Action |
|------|--------|
| `lib/symphony_elixir/config/schema.ex` | Modify — add Opencode schema, update embedded_schema |
| `lib/symphony_elixir/config.ex` | Modify — add agent_provider(), opencode_runtime_settings() |
| `lib/symphony_elixir/agent_runner.ex` | Modify — provider dispatch in run_agent_turns |
| `lib/symphony_elixir/opencode/server.ex` | Create — new module |
| `WORKFLOW.md` | Modify — document agent.provider option |

---

## Testing Approach

1. Unit test Opencode.Server with mock HTTP responses
2. Integration test: set `provider: opencode` in WORKFLOW.md, run orchestrator against a test issue
3. Existing Codex tests unchanged — provider routing preserves existing behavior for `:codex`