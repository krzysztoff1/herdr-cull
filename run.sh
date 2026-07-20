#!/usr/bin/env bash
# Pane `herdr-cull.cull` entrypoint.
#
# Overlay panes don't source your login shell, so Homebrew's bin (where fzf and
# herdr usually live) may be off PATH. Put the common locations back, then hand
# off to the Python review UI. cull.py finds the herdr binary via HERDR_BIN_PATH.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

exec "$(command -v python3 || echo /usr/bin/python3)" "$HERDR_PLUGIN_ROOT/cull.py"
