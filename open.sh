#!/usr/bin/env bash
# Action `herdr-cull.open`: open the review overlay.
#
# Runs on the herdr server (no TTY), so it can't run fzf directly — it opens the
# `cull` overlay pane (see herdr-plugin.toml), which gets a real terminal and runs
# cull.sh. The tool operates on every agent pane in the session regardless of
# directory, so no --cwd forwarding is needed.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

exec "$herdr_bin" plugin pane open \
  --plugin herdr-cull \
  --entrypoint cull \
  --placement overlay \
  --focus
