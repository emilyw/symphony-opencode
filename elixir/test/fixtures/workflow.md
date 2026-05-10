---
tracker:
  kind: linear
  api_key: "test"
  project_slug: "test"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
polling:
  interval_ms: 60000
workspace:
  root: /tmp/symphony_workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: "codex app-server"
hooks:
  after_create: |
    git clone --depth 1 https://github.com/emilyw/symphony-opencode .
    git remote add upstream https://github.com/openai/symphony
    cd elixir && mise trust && mise exec -- mix deps.get
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
observability:
  dashboard_enabled: false
---
Test workflow fixture.
