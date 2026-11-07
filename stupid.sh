#!/usr/bin/env bash
# Stupid Simple Harness (SSH) - keep Claude Code working while you sleep.
# One bash file. Zero tokens. As dumb as it gets. Embrace the stupid.
#
#   stupid [folder] ["prompt"]      start a run (asks for anything missing)
#   stupid --status [folder]        how every run (or one) is doing
#   stupid --attach <folder>        watch it work (detach: Ctrl-b d)
#   stupid --resume <folder>        restart a run from its last conversation
#   stupid --stop   <folder>        stop a run for good
#
# Options for a start:
#   --hours N        work for N hours (default 8)
#   --until HH:MM    ...or until this clock time
#   --budget USD     spend limit for this run (default 50; API list prices)
#   --yolo           run Claude with --dangerously-skip-permissions (see README)
#   -- <args>        anything after -- goes straight to claude, e.g. -- --model sonnet --effort medium
#
# MIT License. https://github.com/A19grey/stupid-simple-harness
VERSION=0.2.0
set -uo pipefail

# ----- knobs (env overrides) -----
HOURS="${SSH_HOURS:-8}"
BUDGET="${SSH_BUDGET:-50}"
YOLO="${SSH_YOLO:-0}"
COMPACT_AT="${SSH_COMPACT_AT:-200000}"   # auto-compact window, tokens
IDLE_MIN="${SSH_IDLE_MIN:-15}"  # watchdog: at the prompt this long -> nudge
HANG_MIN="${SSH_HANG_MIN:-30}"  # watchdog: "working" with no progress this long -> Esc + nudge
WATCH_EVERY="${SSH_WATCH_EVERY:-600}" # watchdog: seconds between checks
GRACE_MIN="${SSH_GRACE_MIN:-45}" # after the deadline: time allowed for the wrap-up
MAX_KICKS=80       # stop hook: max "keep going"s
MAX_NUDGES=20      # watchdog: max nudges
MAX_RESTARTS=12    # crash restarts
REG="$HOME/.stupid-simple-harness/runs"

# ----- tiny helpers -----
now()       { echo "${SSH_FAKE_NOW:-$(date +%s)}"; }
mtime()     { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
hm()        { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M; }
num()       { local v; v=$(cat "$1" 2>/dev/null); echo "${v:-0}"; }
ge()        { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a!="?" && a+0>=b+0)}'; }
abspath()   { (cd "$1" && pwd); }
sess_of()   { echo "stupid-$(basename "$1" | tr -c 'A-Za-z0-9_\n' '_')"; }
ME=$(basename "$0"); command -v "$ME" >/dev/null 2>&1 || ME="$0"   # how you called it: "stupid" or "./stupid.sh"
die()       { echo "$ME: $*" >&2; exit 1; }
usage()     { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }
awake()     {   # keep the computer from sleeping while the command runs
  if command -v caffeinate >/dev/null; then caffeinate -ims "$@"
  elif command -v systemd-inhibit >/dev/null && systemd-inhibit --what=idle --who=ssh --why=test true 2>/dev/null; then systemd-inhibit --what=idle:sleep --who=stupid-simple-harness --why="Claude is working" "$@"
  else "$@"; fi
}
until_epoch() {   # next occurrence of HH:MM
  local t; t=$(date -d "$1" +%s 2>/dev/null || date -j -f "%H:%M" "$1" +%s 2>/dev/null) || die "bad --until '$1' (use HH:MM)"
  [ "$t" -le "$(now)" ] && t=$((t + 86400)); echo "$t"
}

# Per-run state lives in <folder>/.harness/
load() {   # sets D H S SESS and the run config
  D="$(abspath "$1")" || die "no such folder: $1"
  H="$D/.harness"; S="$H"; SESS="$(sess_of "$D")"
  [ -f "$H/config" ] && . "$H/config"
  return 0
}
log() { echo "$(date '+%m-%d %H:%M') $*" >> "$H/log"; }
wrapped()   { [ -f "$H/final_call" ] && [ -f "$H/WRAPPED" ] && [ "$H/WRAPPED" -nt "$H/final_call" ]; }
finished()  { [ -f "$H/OFF" ] || wrapped || [ "$(now)" -gt $((DEADLINE + GRACE_MIN * 60)) ]; }

# ----- spend: read Claude Code's own transcripts, price them. Never asks the model. -----
spend() {
  command -v python3 >/dev/null || { echo "?"; return; }
  python3 - "$1" <<'PY' 2>/dev/null || echo "?"
import json, os, re, sys, glob
from datetime import datetime
P = [  # model-id regex, input, 5m cache write, 1h cache write, cache read, output ($/MTok)
 (r"opus-5-5",4,5,8,.2,20),(r"opus-5",5,6.25,10,.5,25),(r"opus-4-[5-9]",5,6.25,10,.5,25),(r"opus-4",15,18.75,30,1.5,75),
 (r"sonnet-5-5",2,2.5,4,.1,10),(r"sonnet-5",2,2.5,4,.2,10),(r"sonnet-4",3,3.75,6,.3,15),
 (r"haiku-5-5",.1,.125,.2,.01,.5),(r"haiku-4",1,1.25,2,.1,5),
 (r"(fable|mythos)-5-1",10,12.5,20,.25,50),(r"(fable|mythos)",10,12.5,20,1,50)]
FALLBACK = (None,5,6.25,10,.5,25)
proj = os.path.abspath(sys.argv[1]).rstrip("/")
st = os.path.join(proj, ".harness", "started")
since = os.path.getmtime(st) if os.path.exists(st) else 0
base = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "projects")
d = os.path.join(base, re.sub(r"[^A-Za-z0-9]", "-", proj))
if not os.path.isdir(d):
    print("0.00" if os.path.isdir(base) else "?"); sys.exit()
msgs = {}
for f in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True):
    if os.path.getmtime(f) < since: continue
    for line in open(f, errors="ignore"):
        if '"usage"' not in line: continue
        try: e = json.loads(line)
        except Exception: continue
        m = e.get("message") or {}
        u = m.get("usage") if isinstance(m, dict) else None
        if not u: continue
        try: t = datetime.fromisoformat(e.get("timestamp","").replace("Z","+00:00")).timestamp()
        except Exception: t = 0
        if t < since: continue
        k = (m.get("id") or "") + "|" + (e.get("requestId") or "")
        if k == "|": k = line
        if k not in msgs or (u.get("output_tokens") or 0) >= (msgs[k][1].get("output_tokens") or 0):
            msgs[k] = (m.get("model") or "", u)
total = 0.0
for model, u in msgs.values():
    if model == "<synthetic>": continue
    p = next((x for x in P if re.search(x[0], model)), FALLBACK)
    i, r = u.get("input_tokens") or 0, u.get("cache_read_input_tokens") or 0
    cc = u.get("cache_creation") or {}
    w1 = cc.get("ephemeral_1h_input_tokens") or 0
    w5 = cc.get("ephemeral_5m_input_tokens")
    if w5 is None: w5 = max(0, (u.get("cache_creation_input_tokens") or 0) - w1)
    o = u.get("output_tokens") or 0
    mult = 5 if "haiku-5-5" in model and i + r + w5 + w1 > 100000 else 1
    total += mult * (i*p[1] + w5*p[2] + w1*p[3] + r*p[4] + o*p[5]) / 1e6
print(f"{total:.2f}")
PY
}

# ----- the rules Claude gets (appended to its system prompt, survives compaction) -----
write_rules() {
  cat > "$H/rules.md" <<EOF
# Stupid Simple Harness: you are running unattended
Your human started you and walked away. Nobody will answer questions until the run ends.
- The task is in PROMPT.md in this folder. Work alone. When unsure, decide, write the decision in NOTES.md, and keep going.
- Keep a plan in PLAN.md as checkboxes ("- [ ] ..."). Tick a box ("- [x]") only after that step is tested and committed.
- Commit to git after every milestone. Never push.
- Do not end your turn to report progress or to ask a question. A harness will send you back to work.
- Wrap long, network or hardware commands in a timeout so one hung command cannot eat the night.
- Keep context small: summarize big outputs, do not print whole logs or tables.
- Deadline: $(hm "$DEADLINE") (local time). Budget: about \$$BUDGET of model spend, measured by the harness from your transcripts.
- If PLAN.md is done and there is time and budget left, raise the bar: better visuals, deeper analysis, better sources, a different approach that could win, more tests. Add new checkboxes and keep going. "Done" before the deadline is not a reason to stop.
- When the harness says time is up or the budget is used: stop building, write SUMMARY.md (what you built, how to try it, what is missing, what the human should do first), commit, then run: touch .harness/WRAPPED
EOF
}

write_settings() {
  local hook="$H/stupid.sh --_hook"
  cat > "$H/settings.json" <<EOF
{
  "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "$COMPACT_AT" },
  "permissions": { "deny": ["Bash(git push *)", "Bash(git push)"] },
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "$hook" } ] } ] }
}
EOF
}

claude_cmd() {   # $1 = first message; extra: --continue
  local first="$1"; shift
  local perm=(--permission-mode acceptEdits)
  [ "$YOLO" = 1 ] && perm=(--dangerously-skip-permissions)
  awake claude "$@" "${perm[@]}" --settings "$H/settings.json" \
    --append-system-prompt "$(cat "$H/rules.md")" ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} "$first"
}

# ----- inside tmux window "claude": run Claude, restart it if it dies -----
run_loop() {
  local mode="$1" first=1 rc r
  echo $$ > "$H/running.pid"
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$COMPACT_AT"
  while :; do
    r=$(num "$H/restarts")
    [ "$r" -ge "$MAX_RESTARTS" ] && { log "restart cap reached"; break; }
    if [ "$mode" = fresh ] && [ $first = 1 ]; then
      claude_cmd "$(cat "$D/PROMPT.md")"
    else
      claude_cmd "You were restarted after a crash or exit (restart $r). Nobody is awake. Re-read PROMPT.md, PLAN.md, NOTES.md and git log, check the state of anything you were driving, then continue." --continue
    fi
    rc=$?; first=0
    finished && { log "claude exited rc=$rc, run finished"; break; }
    echo $((r + 1)) > "$H/restarts"; log "claude exited rc=$rc, restarting in 20s ($((r + 1))/$MAX_RESTARTS)"
    sleep 20
  done
  rm -f "$H/running.pid"
  echo; echo "Claude is not running. Restart: $ME --resume $D"
  exec "${SHELL:-/bin/bash}" -l
}

# ----- Stop hook: runs every time Claude tries to end its turn -----
hook() {
  cat > /dev/null
  load "${CLAUDE_PROJECT_DIR:-$PWD}"; cd "$D" || exit 0
  [ -f "$H/config" ] || exit 0
  [ -f "$H/OFF" ] && exit 0
  local n spend_now hard t focus left head last stall msg
  block() { printf '{"decision":"block","reason":"%s"}\n' "$1"; exit 0; }
  n=$(( $(num "$H/kicks") + 1 )); echo "$n" > "$H/kicks"
  [ "$n" -gt "$MAX_KICKS" ] && exit 0
  spend_now=$(spend "$D"); hard=$(awk -v b="$BUDGET" 'BEGIN{printf "%.2f", b*1.25}')
  msg="$(hm "$(now)"), deadline $(hm "$DEADLINE"), spend \$${spend_now/\?/unknown} of \$$BUDGET"
  if ge "$spend_now" "$hard"; then touch "$H/OFF"; log "hard budget stop (\$$spend_now)"; exit 0; fi
  t=""
  [ "$(now)" -ge "$DEADLINE" ] && t="time is up"
  ge "$spend_now" "$BUDGET" && t="the budget is used"
  if [ -n "$t" ]; then
    [ -f "$H/final_call" ] || { touch "$H/final_call"; log "wrap-up: $t"; }
    wrapped && exit 0
    [ "$(now)" -gt $((DEADLINE + GRACE_MIN * 60)) ] && exit 0
    block "Harness ($msg): $t. Stop building. Write SUMMARY.md (what you built, how to try it, what is missing, what to do first), commit, then run: touch .harness/WRAPPED"
  fi
  head=$(git rev-parse -q --verify HEAD 2>/dev/null); head="${head:-none}"
  last=$(cat "$H/head" 2>/dev/null); echo "$head" > "$H/head"
  stall=""; [ "$head" = "$last" ] && stall=" No new commit since the last check: if one problem has taken 3 tries or 20 minutes, change the approach and write down why."
  left=$(grep -c '^[[:space:]]*- \[ \]' PLAN.md 2>/dev/null); left="${left:-no PLAN.md yet}"
  if [ "$left" != "0" ]; then
    block "Harness ($msg): nobody is awake, so do not wait for an answer. Keep going: re-read PLAN.md ($left unchecked), do the next step, test it, commit, tick it.$stall"
  fi
  case $((n % 5)) in
    0) focus="better visuals: clearer charts, an interactive view, a more convincing demo" ;;
    1) focus="deeper analysis: more data, segments, error bars, and what would change the conclusion" ;;
    2) focus="better or more detailed sources: data, logs, docs or prior work that could confirm or overturn the result" ;;
    3) focus="a different plan of attack that could beat the current one: try it small, compare, keep the winner" ;;
    4) focus="robustness: tests, edge cases, a reproducible script and a short README" ;;
  esac
  block "Harness ($msg): PLAN.md is done but there is time and budget left, so the run is not over. Raise the bar. This round, focus on $focus. Add 1 to 3 new - [ ] steps to PLAN.md, build the most valuable one, test, commit.$stall"
}

# ----- inside tmux window "watch": restart, unstick, enforce budget. Zero tokens. -----
last_activity() {
  local best=0 m f h enc
  enc=$(printf '%s' "$D" | sed 's/[^A-Za-z0-9]/-/g')
  for f in $(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc" -name '*.jsonl' -type f 2>/dev/null); do
    m=$(mtime "$f"); [ "$m" -gt "$best" ] && best=$m
  done
  h=$(tmux capture-pane -p -t "$SESS:claude" 2>/dev/null | grep -v interrupt | tr -cd 'A-Za-z\n' | cksum)
  if [ "$h" != "$(cat "$H/pane_hash" 2>/dev/null)" ]; then echo "$h" > "$H/pane_hash"; now > "$H/pane_time"; fi
  for m in "$(num "$H/pane_time")" "$(mtime "$H/started")" "$(mtime "$H/restarts")"; do [ "$m" -gt "$best" ] && best=$m; done
  echo "$best"
}
say() { tmux send-keys -t "$SESS:claude" -l "$1"; sleep 1; tmux send-keys -t "$SESS:claude" Enter; }

watch_once() {
  local pid pane idle n s hard
  finished && return 1
  s=$(spend "$D"); hard=$(awk -v b="$BUDGET" 'BEGIN{printf "%.2f", b*1.25}')
  if ge "$s" "$hard"; then
    touch "$H/OFF"; tmux send-keys -t "$SESS:claude" Escape 2>/dev/null; sleep 2
    log "HARD budget stop: \$$s >= \$$hard"; tmux kill-session -t "$SESS"; return 1
  fi
  pid=$(cat "$H/running.pid" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    [ "$(num "$H/restarts")" -ge "$MAX_RESTARTS" ] && return 1
    echo $(( $(num "$H/restarts") + 1 )) > "$H/restarts"
    if tmux list-windows -t "$SESS" -F '#W' 2>/dev/null | grep -qx claude; then
      tmux respawn-window -k -t "$SESS:claude" "'$H/stupid.sh' --_run '$D' resume"
    else
      tmux new-window -d -t "$SESS:" -n claude -c "$D" "'$H/stupid.sh' --_run '$D' resume"
    fi
    log "watchdog: Claude loop not running -> restarted"; return 0
  fi
  pane=$(tmux capture-pane -p -t "$SESS:claude" | tail -30)
  idle=$(( ($(now) - $(last_activity)) / 60 ))
  if grep -qE 'Do you want to (proceed|make this edit|create|allow)|❯ 1\. Yes' <<<"$pane"; then
    log "watchdog: STUCK on a permission prompt (${idle}m). Use --yolo or allow-rules next time."; return 0
  fi
  n=$(num "$H/nudges"); [ "$n" -ge "$MAX_NUDGES" ] && return 0
  if grep -q 'esc to interrupt' <<<"$pane"; then
    if [ "$idle" -ge "$HANG_MIN" ]; then
      tmux send-keys -t "$SESS:claude" Escape; sleep 3
      say "Harness watchdog: the last step ran ${idle} min with no progress, so I interrupted it. Wrap that command in a timeout or try another way, note it in NOTES.md, and continue."
      echo $((n + 1)) > "$H/nudges"; log "watchdog: hung ${idle}m -> Esc + nudge"
    fi
  elif [ "$idle" -ge "$IDLE_MIN" ]; then
    if ge "$s" "$BUDGET" || [ "$(now)" -ge "$DEADLINE" ]; then
      say "Harness watchdog: time or budget is up (spend \$$s of \$$BUDGET). Write SUMMARY.md, commit, then run: touch .harness/WRAPPED"
    else
      say "Harness watchdog: idle ${idle} min, spend \$$s of \$$BUDGET, deadline $(hm "$DEADLINE"). Nobody is awake and the run is not over. Re-read PLAN.md; if it is done, raise the bar (better visuals, deeper analysis, better sources, a different approach, more tests). Keep going."
    fi
    echo $((n + 1)) > "$H/nudges"; log "watchdog: idle ${idle}m -> nudge (\$$s)"
  fi
  return 0
}
watch_loop() { while sleep "$WATCH_EVERY"; do watch_once || break; done; log "watchdog: run finished, watchdog exiting"; }

# ----- user commands -----
start_tmux() {   # $1 = fresh|resume
  tmux new-session -d -s "$SESS" -n claude -c "$D" "'$H/stupid.sh' --_run '$D' $1"
  tmux new-window -d -t "$SESS" -n watch -c "$D" "'$H/stupid.sh' --_watch '$D'"
}
attach() {
  [ -n "${SSH_NO_ATTACH:-}" ] && return 0
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$SESS:claude"; else exec tmux attach -t "$SESS:claude"; fi
}

status_one() {
  load "$1"; [ -f "$H/config" ] || return 0
  local up=down st="running" idle=- s
  tmux has-session -t "$SESS" 2>/dev/null && up=up
  [ -f "$H/final_call" ] && st="wrapping up"; wrapped && st="WRAPPED"; [ -f "$H/OFF" ] && st="OFF"
  finished && [ "$st" = running ] && st="past deadline"
  s=$(spend "$D")
  printf '%-28s %-5s %-6s %13s %5s %6s %8s  %s\n' "$(basename "$D" | cut -c1-28)" $up "$(hm "$DEADLINE")" "\$$s/\$$BUDGET" \
    "$(num "$H/kicks")" "$(num "$H/nudges")" "$(num "$H/restarts")" "$st"
}
status() {
  printf '%-28s %-5s %-6s %13s %5s %6s %8s  %s\n' RUN TMUX UNTIL SPEND KICKS NUDGES RESTARTS STATE
  if [ -n "${1:-}" ]; then status_one "$1"; echo "--- log ---"; tail -8 "$H/log" 2>/dev/null; return; fi
  [ -f "$REG" ] || return 0
  sort -u "$REG" | while IFS= read -r d; do [ -d "$d/.harness" ] && status_one "$d"; done
}

start() {   # $1 folder (maybe empty), $2 prompt (maybe empty)
  local dir="${1:-}" prompt="${2:-}"
  command -v claude >/dev/null || die "claude (Claude Code) is not installed or not on PATH"
  command -v tmux >/dev/null || die "tmux is required: brew install tmux  /  apt install tmux"
  command -v python3 >/dev/null || echo "$ME: warning: no python3, so the budget cannot be measured or enforced" >&2
  if [ -z "$dir" ]; then
    [ -t 0 ] || { usage; exit 1; }
    usage; echo; echo "No folder given, so let's start one."
    read -r -p "Folder for this run (created if new): " dir; [ -n "$dir" ] || die "no folder"
  fi
  dir="${dir/#\~/$HOME}"
  [ -d "$dir" ] || { mkdir -p "$dir" && echo "Created $dir"; }
  load "$dir"
  if tmux has-session -t "$SESS" 2>/dev/null; then echo "$SESS is already running. Attaching ($ME --stop $D to end it)."; attach; return; fi
  if [ -n "$prompt" ]; then printf '%s\n' "$prompt" > "$D/PROMPT.md"
  elif [ ! -s "$D/PROMPT.md" ]; then
    echo "What should Claude do? Paste or type the prompt, then press Ctrl-D on an empty line:"
    cat > "$D/PROMPT.md"; [ -s "$D/PROMPT.md" ] || { rm -f "$D/PROMPT.md"; die "empty prompt"; }
  else
    echo "Using $D/PROMPT.md"
  fi
  mkdir -p "$H"
  rm -f "$H"/{kicks,head,final_call,WRAPPED,OFF,restarts,nudges,pane_hash,pane_time,running.pid}
  local deadline; deadline=$(( $(now) + HOURS * 3600 )); [ -n "${UNTIL:-}" ] && deadline=$(until_epoch "$UNTIL")
  { echo "DEADLINE=$deadline"; echo "BUDGET=$BUDGET"; echo "YOLO=$YOLO"; echo "COMPACT_AT=$COMPACT_AT"
    printf 'CLAUDE_ARGS=('; [ ${#CLAUDE_ARGS[@]} -gt 0 ] && printf '%q ' "${CLAUDE_ARGS[@]}"; echo ')'; } > "$H/config"
  . "$H/config"
  cp "$0" "$H/stupid.sh"; chmod +x "$H/stupid.sh"   # snapshot: editing stupid.sh later never breaks a running run
  touch "$H/started"
  write_rules; write_settings
  if ! git -C "$D" rev-parse --git-dir >/dev/null 2>&1; then git -C "$D" init -q; fi
  grep -qxF '.harness/' "$D/.gitignore" 2>/dev/null || echo '.harness/' >> "$D/.gitignore"
  mkdir -p "$(dirname "$REG")"; echo "$D" >> "$REG"
  log "start: until $(hm "$DEADLINE"), budget \$$BUDGET, yolo=$YOLO, args: ${CLAUDE_ARGS[*]+${CLAUDE_ARGS[*]}}"
  start_tmux fresh
  echo "Stupid Simple Harness: $SESS is running until $(hm "$DEADLINE") with a \$$BUDGET budget."
  [ "$YOLO" = 1 ] || echo "  Note: without --yolo, any permission prompt will wait for you. Approve them now with 'don't ask again'."
  echo "  Stay for the first minute (folder trust prompt), then detach with Ctrl-b d. Check later: $ME --status"
  attach
}

# ----- argument parsing -----
CLAUDE_ARGS=(); POS=(); CMD=start; UNTIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|-help|--help|help) usage; exit 0 ;;
    --version)  echo "stupid-simple-harness $VERSION"; exit 0 ;;
    --hours)    HOURS="$2"; shift 2 ;;
    --until)    UNTIL="$2"; shift 2 ;;
    --budget)   BUDGET="$2"; shift 2 ;;
    --yolo)     YOLO=1; shift ;;
    --status|--attach|--resume|--stop) CMD="${1#--}"; shift ;;
    --_run)     CMD=_run; shift ;;
    --_watch)   CMD=_watch; shift ;;
    --_hook)    CMD=_hook; shift ;;
    --)         shift; CLAUDE_ARGS=("$@"); break ;;
    -*)         echo "$ME: unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)          POS+=("$1"); shift ;;
  esac
done
case "$HOURS" in ''|*[!0-9]*) die "--hours must be a whole number" ;; esac

case "$CMD" in
  start)  start "${POS[0]:-}" "${POS[1]:-}" ;;
  status) status "${POS[0]:-}" ;;
  attach) [ -n "${POS[0]:-}" ] || die "usage: $ME --attach <folder>"; load "${POS[0]}"; attach ;;
  stop)   [ -n "${POS[0]:-}" ] || die "usage: $ME --stop <folder>"; load "${POS[0]}"
          touch "$H/OFF"; tmux kill-session -t "$SESS" 2>/dev/null; log "stopped by hand"; echo "Stopped $SESS." ;;
  resume) [ -n "${POS[0]:-}" ] || die "usage: $ME --resume <folder>"; load "${POS[0]}"
          [ -f "$H/config" ] || die "no run in $D yet: start one with $ME $D"
          rm -f "$H/OFF" "$H/restarts"
          [ -x "$H/stupid.sh" ] || { cp "$0" "$H/stupid.sh"; chmod +x "$H/stupid.sh"; }   # runs started before the rename only have go.sh
          if ! tmux has-session -t "$SESS" 2>/dev/null; then start_tmux resume; log "resumed by hand"; fi
          attach ;;
  _run)   load "${POS[0]}"; run_loop "${POS[1]:-resume}" ;;
  _watch) load "${POS[0]}"; watch_loop ;;
  _hook)  hook ;;
esac
