# herdr-cull

Review and close **idle agent panes** in [herdr](https://herdr.dev).

> **Why "cull"?** In shepherding, to *cull* is to go through the flock and remove
> the animals that shouldn't stay. That's exactly what this plugin does for your
> agents: it rounds up the ones that have gone idle, shows you the flock, and
> removes only the ones you pick. (It fits herdr's herding theme — and unlike
> "kill", culling is deliberate and reviewed, never automatic.)

If you drive a fleet of coding agents (Claude, Codex, …) across many tabs, some
of them finish, go quiet, and just sit there for hours. `herdr-cull` finds those
stale panes and lets you clear them out — but always shows you the list first, so
nothing is closed without your say-so.

![fzf multi-select of idle agent panes](docs/screenshot.png)

## How it decides what's "idle"

herdr knows an agent's *status* (`idle` / `working`) but not *when it last did
something*. So staleness is measured from the modification time of the agent's
**session transcript**, which Claude and Codex append to on every turn:

| Agent  | Transcript looked up at                     | Status              |
| ------ | ------------------------------------------- | ------------------- |
| Claude | `~/.claude/projects/*/<session-id>.jsonl`   | ✅ fully supported  |
| Codex  | `~/.codex/sessions/**/*<session-id>*.jsonl` | ⏳ waiting on herdr  |

> **Codex note:** herdr does not yet report a session id for Codex panes, so
> `herdr-cull` can't tie a Codex pane to its rollout file — those panes are
> **skipped** (shown in the "no readable session file" count), never closed. The
> lookup above already works and will light up automatically once herdr exposes a
> Codex session handle. Correlating by directory was considered and rejected: two
> Codex panes in the same repo would be indistinguishable, and mis-attributing a
> pane is exactly the mistake this tool exists to avoid.

A pane is a candidate when **all** of these hold:

- it is an agent pane,
- its agent is **not** currently `working`,
- its transcript hasn't been touched for at least the **idle threshold** (default **4h**).

Panes whose transcript can't be located are skipped (and counted), never closed.

## Usage

Invoke the action however you like:

```sh
herdr plugin action invoke herdr-cull.open
```

…but you'll want a keybinding. herdr 0.7 does not bind keys from plugin
manifests, so add this to `~/.config/herdr/config.toml` and run
`herdr server reload-config`:

```toml
[[keys.command]]
key = "ctrl+shift+k"
type = "plugin_action"
command = "herdr-cull.open"
description = "Review & close idle agent panes"
```

An overlay opens with an [fzf](https://github.com/junegunn/fzf) multi-select:

- **Tab** — mark a pane for closing
- **Ctrl-A** — mark all
- **Enter** — close the marked panes
- **Esc** — cancel (closes nothing)

When the marked agent is the only pane in its tab, the whole tab is closed;
otherwise just the pane is removed.

## Configuration

Set the idle threshold (in hours) either way — env wins:

```sh
export HERDR_CULL_IDLE_HOURS=8
```

```toml
# <plugin-config-dir>/config.toml   (herdr plugin config-dir herdr-cull)
idle_hours = 8
```

## Requirements

- herdr ≥ 0.7.0
- Python 3 (standard library only)
- [fzf](https://github.com/junegunn/fzf) — recommended for the multi-select UI.
  Without it, `herdr-cull` falls back to a simple per-pane `[y/N]` prompt.

## Install

```sh
herdr plugin install krzysztoff1/herdr-cull
```

Or, for local development:

```sh
git clone https://github.com/krzysztoff1/herdr-cull
herdr plugin link ./herdr-cull
```

## License

MIT — see [LICENSE](LICENSE).
