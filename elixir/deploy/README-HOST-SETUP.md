# Symphony host setup for Jam + shopify-draft-proxy + durababble + shot-caller

This host now has:
- `openai/symphony` cloned at `/home/airhorns/code/symphony`
- Elixir 1.19.5 / OTP 28 installed via Nix profile
- `codex` installed at `~/.local/bin/codex`
- `opencode` installed at `~/.local/bin/opencode`
- Symphony built at `/home/airhorns/code/symphony/elixir/bin/symphony`
- Per-repo workflow/env files and systemd user units for:
  - `symphony-jam.service`
  - `symphony-shopify-draft-proxy.service`
  - `symphony-durababble.service`
  - `symphony-shot-caller.service`

## Files

- Runner script:
  - `/home/airhorns/code/symphony/elixir/deploy/run-workflow.sh`
- OpenCode compatibility bridge:
  - `/home/airhorns/code/symphony/elixir/deploy/harness/opencode_app_server.py`
- Workflow templates / repo workflows:
  - `/home/airhorns/code/symphony/elixir/deploy/workflows/jam.WORKFLOW.template.md`
  - `/home/airhorns/code/symphony/elixir/deploy/workflows/shopify-draft-proxy.WORKFLOW.template.md`
  - `/home/airhorns/code/jam/WORKFLOW.md`
  - `/home/airhorns/code/shopify-draft-proxy/WORKFLOW.md`
  - `/home/airhorns/code/durababble/WORKFLOW.md`
  - `/home/airhorns/code/shot-caller/WORKFLOW.md`
  - `/home/airhorns/code/symphony/elixir/deploy/workflows/shot-caller.WORKFLOW.template.md`
- Env files:
  - `/home/airhorns/code/symphony/elixir/deploy/env/jam.env`
  - `/home/airhorns/code/symphony/elixir/deploy/env/shopify-draft-proxy.env`
  - `/home/airhorns/code/symphony/elixir/deploy/env/durababble.env`
  - `/home/airhorns/code/symphony/elixir/deploy/env/shot-caller.env`
- systemd user units:
  - `~/.config/systemd/user/symphony-jam.service`
  - `~/.config/systemd/user/symphony-shopify-draft-proxy.service`
  - `~/.config/systemd/user/symphony-durababble.service`
  - `~/.config/systemd/user/symphony-shot-caller.service`

## Required configuration

Before starting a service, set at least:
- `LINEAR_PROJECT_SLUG` in the relevant env file
- `LINEAR_API_KEY` in the service environment or env file

Optional per-instance values:
- `LINEAR_ASSIGNEE` (`me` is preferred for this host)
- `CODING_HARNESS` (`codex`, `opencode`, or `custom`)
- `CODEX_COMMAND` (explicit app-server command; only needed for codex/custom overrides)
- `OPENCODE_MODEL` when `CODING_HARNESS=opencode`
- `SYMPHONY_PORT`
- `SYMPHONY_HOST` (currently this host's Tailscale IP so dashboards are reachable on the tailnet)
- workspace/log locations

`CODING_HARNESS=opencode` runs Symphony through `deploy/harness/opencode_app_server.py`, a small Codex app-server protocol bridge that delegates turns to `opencode run --format json --auto`. The bridge loads Hermes' OpenRouter key from `/home/airhorns/.hermes/.env` if `OPENROUTER_API_KEY` is not already in the service environment. The shot-caller instance is intentionally configured with `OPENCODE_MODEL=openrouter/z-ai/glm-5.2`; do not switch that instance back to an OpenAI/GPT model.

The runner deliberately ignores a leaked parent-shell `CODEX_COMMAND` when the env file does not set one and `CODING_HARNESS` is `codex` or `opencode`; this keeps one instance's command from bleeding into another instance during manual renders.

## Useful commands

Reload user units:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user daemon-reload
```

Render a workflow to inspect the concrete config without starting Symphony:

```bash
/home/airhorns/code/symphony/elixir/deploy/run-workflow.sh \
  /home/airhorns/code/symphony/elixir/deploy/env/shot-caller.env \
  /home/airhorns/code/symphony/elixir/deploy/workflows/shot-caller.WORKFLOW.template.md \
  --render-only
```

Start/enable Jam:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user enable --now symphony-jam.service
```

Start/enable shopify-draft-proxy:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user enable --now symphony-shopify-draft-proxy.service
```

Start/enable durababble:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user enable --now symphony-durababble.service
```

Start/enable shot-caller after its Linear project slug is set:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user enable --now symphony-shot-caller.service
```

Tail logs:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u symphony-jam.service -f
XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u symphony-shopify-draft-proxy.service -f
XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u symphony-durababble.service -f
XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u symphony-shot-caller.service -f
```

## Notes

- `shot-caller` uses `CODING_HARNESS=opencode` with `OPENCODE_MODEL=openrouter/z-ai/glm-5.2`; its workspace bootstrap runs `lnai sync` + `lnai validate`, creates `.env` as a symlink to `/home/airhorns/code/shot-caller/.env.shared`, and shares caches under `/home/airhorns/.cache/shot-caller`, and links `.venv` to `/home/airhorns/code/shot-caller/.venv` before `direnv allow`. The OpenCode bridge sets `OPENCODE_DISABLE_CLAUDE_CODE=1`; shot-caller agents should use `AGENTS.md` and `.agents/skills/*`, never `.claude`.
- `shopify-draft-proxy` and `shot-caller` use Linear webhooks as the primary trigger. Their workflow polling intervals are set to `10800000` ms (3h) as a backup only.
- Public ingress for Linear is intentionally narrow: Kubernetes/Traefik exposes only the exact `/api/v1/linear/webhook` path on `linear-shopify-draft-proxy.shot-caller.win` and `linear-shot-caller.shot-caller.win`, routing to Thompson ports `4312` and `4314` respectively. Webhook HMAC secrets live only in the corresponding env files as `LINEAR_WEBHOOK_SECRET`; project prefilter IDs live in `LINEAR_PROJECT_ID` so unrelated webhook deliveries can be ignored before any Linear API call.
- `shopify-draft-proxy` bootstraps `.env.example` to `.env` inside each workspace if no `.env` exists yet. Real live-conformance credentials may still be required for some tasks.
- Jam workflows prefer `mise exec -- ...` when the repo pins tool versions with `mise.toml`.
- Use `XDG_RUNTIME_DIR=/run/user/$(id -u)` for `systemctl --user` from shpool shells.
