#!/usr/bin/env bash
# herdr-cull — review & close agent panes.  (bash + jq + fzf)
#
# One overlay lists every non-working agent pane in two groups:
#   • stale           — idle at least the threshold (default 4h), flagged gold/red
#   • active recently — under the threshold, unflagged but still selectable
# herdr tracks an agent's *status* (idle/working) but not *when* it last did
# anything, so idle time is measured from the mtime of the agent's session
# transcript — Claude and Codex append to it on every turn. Working agents are
# never offered. Review is an fzf multi-select: mark what to close and confirm;
# nothing closes otherwise.
#
# Config (first match wins): env HERDR_CULL_IDLE_HOURS · `idle_hours` in
# <plugin-config-dir>/config.toml · default 4. This sets the stale cutoff.
# Debug: CULL_LIST_ONLY=1 (print candidates, no prompt) · CULL_DRY_RUN=1.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
shopt -s nullglob

herdr="${HERDR_BIN_PATH:-herdr}"
LIST_ONLY="${CULL_LIST_ONLY:-0}"
DRY_RUN="${CULL_DRY_RUN:-0}"
esc=$'\033'; red="${esc}[91m"; gold="${esc}[93m"; dim="${esc}[90m"; rst="${esc}[0m"
dash='──────────────────────────────────────────────────────'

pause() {
  printf '\nPress any key to close…'
  if [ -r /dev/tty ]; then
    stty -icanon -echo </dev/tty 2>/dev/null || true
    dd bs=1 count=1 </dev/tty >/dev/null 2>&1 || true
    stty icanon echo </dev/tty 2>/dev/null || true
  else
    sleep 2
  fi
}

die() { printf '%s\n' "$*" >&2; [ "$LIST_ONLY" = 1 ] || pause; exit 1; }

command -v jq >/dev/null 2>&1 || die "herdr-cull: jq is required (brew install jq)."

# --- stale cutoff (hours) ---
# `warn` is the staleness reference: panes idle >= warn are grouped as "stale"
# and flagged (gold >= warn, red >= 2*warn). Everything else is still listed and
# still selectable, just under the "active recently" group.
warn="${HERDR_CULL_IDLE_HOURS:-}"
if [ -z "$warn" ] && [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$HERDR_PLUGIN_CONFIG_DIR/config.toml" ]; then
  warn="$(sed -n 's/^[[:space:]]*idle_hours[[:space:]]*=[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' \
    "$HERDR_PLUGIN_CONFIG_DIR/config.toml" | head -1)"
fi
[ -n "$warn" ] || warn=4

now="$(date +%s)"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Newest mtime of the agent's session transcript, or nothing if not found.
session_mtime() {
  local agent="$1" val="$2" f newest="" m
  local files=()
  [ -n "$val" ] || return 0
  [ "$agent" != "codex" ]  && files+=( "$HOME"/.claude/projects/*/"$val".jsonl )
  if [ "$agent" != "claude" ]; then
    # Codex rollouts nest as ~/.codex/sessions/YYYY/MM/DD/rollout-*<uuid>*.jsonl.
    # Resolve with find, not a `**` glob: the bash running this is often 3.2
    # (macOS system bash) with no globstar, where `**` collapses to a single
    # level and silently misses the file even when the UUID is correct.
    while IFS= read -r f; do [ -n "$f" ] && files+=( "$f" ); done < <(
      find "$HOME/.codex/sessions" -type f -name "rollout-*${val}*.jsonl" 2>/dev/null)
  fi
  [ ${#files[@]} -gt 0 ] || return 0
  for f in "${files[@]}"; do
    m="$(mtime "$f")" || true
    [ -n "$m" ] || continue
    { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; } && newest="$m"
  done
  [ -n "$newest" ] && printf '%s' "$newest"
}

tilde() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}";; *) printf '%s' "$1";; esac; }

# tab_id -> pane count, as "count tab_id" lines.
tab_counts="$("$herdr" pane list 2>/dev/null | jq -r '.result.panes[].tab_id // empty' | sort | uniq -c)"
tab_pane_count() { printf '%s\n' "$tab_counts" | awk -v t="$1" '$2==t{print $1; f=1} END{if(!f) print 99}'; }

# age cell: "  9.3h idle" when known, "    —  idle" when age is unknown (-1).
age_cell() {
  if awk -v x="$1" 'BEGIN{exit !(x<0)}'; then printf '    —  idle'; else printf '%5.1fh idle' "$1"; fi
}
# gold at >= warn, red at >= 2*warn; unknown/fresh ages get no colour.
color_for() {
  awk -v x="$1" -v t="$warn" 'BEGIN{exit !(x>=0 && x>=2*t)}' && { printf '%s' "$red"; return; }
  awk -v x="$1" -v t="$warn" 'BEGIN{exit !(x>=0 && x>=t)}'   && { printf '%s' "$gold"; return; }
}
label_age() { awk -v x="$1" 'BEGIN{ if (x<0) printf "idle"; else printf "%.1fh", x }'; }
fmt_row() { printf '%s%s%s  │  %-44.44s  │  %-6s  │  %s' "$7" "$(age_cell "$1")" "$rst" "$5" "$4" "$6"; }
fmt_plain() { fmt_row "$1" "$2" "$3" "$4" "$5" "$6" ""; }
fmt_color() { fmt_row "$1" "$2" "$3" "$4" "$5" "$6" "$(color_for "$1")"; }
# is the age (>=0) at or past the stale cutoff?
is_stale() { awk -v x="$1" -v t="$warn" 'BEGIN{exit !(x>=0 && x>=t)}'; }
# a non-selectable group divider row: empty pid/tid, dim label in field 3.
group_row() { printf '\t\t%s── %s %s%s' "$dim" "$1" "$dash" "$rst"; }

# --- gather every non-working agent pane ---
agents_tsv="$("$herdr" agent list 2>/dev/null | jq -r '
  .result.agents[]
  | select(.agent != null and .agent_status != "working")
  | [ .pane_id, .tab_id, .agent, (.agent_session.value // ""),
      ((.terminal_title_stripped // "(no title)") | gsub("^[[:space:]]+|[[:space:]]+$";"")),
      (.foreground_cwd // .cwd // "") ] | @tsv')"

cand=""       # age \t pid \t tid \t agent \t title \t cwd   (sortable by age)
labels=""     # pid \t "age  title"

while IFS=$'\t' read -r pid tid agent val title cwd; do
  [ -n "$pid" ] || continue
  m="$(session_mtime "$agent" "$val")"
  if [ -z "$m" ]; then
    age="-1"    # no transcript to age from — still listed (active group), closable by hand
  else
    age="$(awk -v n="$now" -v a="$m" 'BEGIN{printf "%.1f",(n-a)/3600}')"
  fi
  cwds="$(tilde "$cwd")"
  cand+="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$age" "$pid" "$tid" "$agent" "$title" "$cwds")"$'\n'
  labels+="$(printf '%s\t%s  %s' "$pid" "$(label_age "$age")" "$title")"$'\n'
done <<< "$agents_tsv"

label_for() { printf '%s' "$labels" | awk -F'\t' -v p="$1" '$1==p{print $2; exit}'; }

if [ -z "$cand" ]; then
  printf '✓ No agent panes to review (nothing idle or finished).\n'
  [ "$LIST_ONLY" = 1 ] || pause
  exit 0
fi

# sort by age desc: stalest first, unknown (-1) last
sorted="$(printf '%s' "$cand" | sort -t$'\t' -k1,1 -rn)"

# --- list-only (debug) ---
if [ "$LIST_ONLY" = 1 ]; then
  ns="$(printf '%s' "$sorted" | awk -F'\t' -v t="$warn" '$1>=0 && $1>=t' | grep -c .)"
  na="$(printf '%s' "$sorted" | awk -F'\t' -v t="$warn" '!($1>=0 && $1>=t)' | grep -c .)"
  printf 'warn=%sh  stale=%s  active=%s\n' "$warn" "$ns" "$na"
  while IFS=$'\t' read -r age pid tid agent title cwds; do
    [ -n "$pid" ] || continue
    [ "$(tab_pane_count "$tid")" -le 1 ] && act="tab $tid" || act="pane $pid"
    is_stale "$age" && grp=stale || grp=active
    printf '  [%-6s] %s  → close %s\n' "$grp" "$(fmt_plain "$age" "$pid" "$tid" "$agent" "$title" "$cwds")" "$act"
  done <<< "$sorted"
  exit 0
fi

# --- build grouped picker rows: pid \t tid \t coloured-display ---
stale=""; active=""
while IFS=$'\t' read -r age pid tid agent title cwds; do
  [ -n "$pid" ] || continue
  line="$(printf '%s\t%s\t%s' "$pid" "$tid" "$(fmt_color "$age" "$pid" "$tid" "$agent" "$title" "$cwds")")"
  if is_stale "$age"; then stale+="$line"$'\n'; else active+="$line"$'\n'; fi
done <<< "$sorted"

rows=""
[ -n "$stale" ]  && rows+="$(group_row "stale · idle ≥ ${warn}h")"$'\n'"$stale"
[ -n "$active" ] && rows+="$(group_row "active recently · still selectable")"$'\n'"$active"

# --- review (fzf, or y/N fallback) ---
selected=""
if command -v fzf >/dev/null 2>&1; then
  header="$(printf 'Agent panes — stalest first, all selectable\nTab mark · Ctrl-A all · Enter close marked · Esc cancel')"
  selected="$(printf '%s' "$rows" | fzf --multi --ansi --delimiter=$'\t' --with-nth=3.. \
    --layout=reverse --height=100% --border --marker='✗ ' --pointer='▶' \
    --prompt='close ▸ ' --header="$header" --header-first --bind 'ctrl-a:toggle-all')" || true
else
  while IFS=$'\t' read -r pid tid disp; do
    if [ -z "$pid" ]; then [ -n "$disp" ] && printf '\n%s\n' "$disp" >/dev/tty; continue; fi
    printf 'Close %s? [y/N] ' "$disp" >/dev/tty
    read -r ans </dev/tty || true
    case "$ans" in y|Y) selected+="$pid"$'\t'"$tid"$'\n';; esac
  done <<< "$rows"
fi

# drop group-divider lines (empty pid) from whatever came back
selected="$(printf '%s' "$selected" | awk -F'\t' 'NF>=2 && $1!=""')"

if [ -z "$selected" ]; then
  echo "Cancelled — nothing closed."
  pause
  exit 0
fi

# --- close (whole tab when the agent is its only pane, else just the pane) ---
closed=0; total=0; done_tabs=$'\n'
while IFS=$'\t' read -r pid tid _; do
  [ -n "$pid" ] || continue
  if [ "$(tab_pane_count "$tid")" -le 1 ]; then
    case "$done_tabs" in *$'\n'"$tid"$'\n'*) continue;; esac
    done_tabs+="$tid"$'\n'
    kind="tab"; ident="$tid"
  else
    kind="pane"; ident="$pid"
  fi
  total=$((total + 1))
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] would close %s %s  (%s)\n' "$kind" "$ident" "$(label_for "$pid")"
    continue
  fi
  if "$herdr" "$kind" close "$ident" >/dev/null 2>&1; then
    closed=$((closed + 1))
    printf '✓ closed %s %s  (%s)\n' "$kind" "$ident" "$(label_for "$pid")"
  else
    printf '✗ failed to close %s %s\n' "$kind" "$ident"
  fi
done <<< "$selected"

[ "$DRY_RUN" = 1 ] || printf '\nClosed %s/%s.\n' "$closed" "$total"
pause
