# Stupid Simple Harness

## Embrace the stupid.

**Keep Claude Code working while you sleep. One bash file. Zero tokens. As dumb as it gets.**

Yes, it's SSH. No, not that one.

```bash
stupid csv-report "Build a CLI that turns our CSV exports into a weekly report"
```

Then go to bed. In the morning there's a git history, a `PLAN.md` full of ticked boxes, and a `SUMMARY.md` telling you what got built and what to look at first.

---

## Why

Claude Code is great until it decides it's done at 11:40 pm, asks you a question at 1 am, or crashes at 3 am. Then it sits there until morning.

The usual fix is an "orchestration layer". This is the opposite of that. Stupid Simple Harness never calls a model, so it costs nothing to run. It's three dumb loops wrapped around Claude Code, short enough to read in one sitting.

## See it work

### 11:02 pm: start it

```console
$ stupid csv-report --until 07:00 --budget 30 "Build a CLI that turns our CSV exports into a weekly report"
Created csv-report
Stupid Simple Harness: stupid-csv_report is running until 07:00 with a $30 budget.
  Note: without --yolo, any permission prompt will wait for you. Approve them now with 'don't ask again'.
  Stay for the first minute (folder trust prompt), then detach with Ctrl-b d. Check later: stupid --status
```

Claude Code opens in tmux with your prompt and starts planning. Watch it for a minute, approve anything it asks, then press **Ctrl-b d** and go to bed.

### 11:40 pm: Claude thinks it's done. The harness disagrees.

Every time Claude tries to end its turn, the stop hook answers instead of you. If `PLAN.md` still has open boxes:

```text
Harness (23:40, deadline 07:00, spend $6.10 of $30): nobody is awake, so do not wait for an answer.
Keep going: re-read PLAN.md (3 unchecked), do the next step, test it, commit, tick it.
```

When the plan is finished but the night isn't, it raises the bar, with a different focus each time:

```text
Harness (01:15, deadline 07:00, spend $11.80 of $30): PLAN.md is done but there is time and budget
left, so the run is not over. Raise the bar. This round, focus on better visuals: clearer charts, an
interactive view, a more convincing demo. Add 1 to 3 new - [ ] steps to PLAN.md, build the most
valuable one, test, commit.
```

The other focuses rotate through deeper analysis, better sources, a different approach that could beat the current one, and robustness.

### 2:00 am: you wake up and check your phone over SSH (the other one)

```console
$ stupid --status
RUN                          TMUX  UNTIL          SPEND KICKS NUDGES RESTARTS  STATE
csv-report                   up    07:00     $14.20/$30    14      2        1  running
flaky-tests                  up    05:00     $22.75/$25     9      0        0  running
```

*Kicks* are times the stop hook sent Claude back to work. *Nudges* are times the watchdog woke up an idle or stuck session. *Restarts* are crashes it recovered from.

### 7:00 am: time's up

At the deadline (or the budget), the hook switches to:

```text
Harness (07:00, deadline 07:00, spend $24.90 of $30): time is up. Stop building. Write SUMMARY.md
(what you built, how to try it, what is missing, what to do first), commit, then run: touch .harness/WRAPPED
```

Claude writes the summary, commits, and is allowed to stop. Over coffee:

```console
$ cat csv-report/.harness/log
11-06 23:02 start: until 07:00, budget $30, yolo=0, args: --model sonnet
11-07 01:48 claude exited rc=1, restarting in 20s (1/12)
11-07 03:21 watchdog: idle 17m -> nudge ($16.40)
11-07 04:05 watchdog: hung 31m -> Esc + nudge
11-07 07:00 wrap-up: time is up

$ cat csv-report/SUMMARY.md     # what got built, how to try it, what's missing
$ git -C csv-report log --oneline | head
```

*(The numbers above are an example night. The message formats are exactly what `stupid.sh` prints.)*

## How it works

```
                 ┌──────────────── tmux session "stupid-<folder>" ────────────────┐
  stupid   ───►  │  window "claude"                    window "watch"             │
                 │  ┌───────────────────────────┐      ┌────────────────────────┐ │
                 │  │ restart loop              │      │ watchdog, every 10 min │ │
                 │  │   claude  ◄── Stop hook   │ ◄─── │  dead?  -> restart     │ │
                 │  │   (crash? --continue)     │      │  idle?  -> nudge       │ │
                 │  └───────────────────────────┘      │  hung?  -> Esc + nudge │ │
                 │                                     │  $$$?   -> hard stop   │ │
                 │                                     └────────────────────────┘ │
                 └────────────────────────────────────────────────────────────────┘
```

| Loop | When it runs | What it does |
|---|---|---|
| **Stop hook** | Every time Claude tries to end its turn | Sends it back to work: the next step in `PLAN.md`, or "raise the bar" if the plan is done. At the deadline or budget it asks for `SUMMARY.md`, then lets Claude stop. |
| **Restart loop** | When Claude exits or crashes | Restarts it with `--continue` after 20 seconds, with a note to re-read the plan. |
| **Watchdog** | Every 10 minutes | Restarts a dead session, nudges an idle one, presses Esc on a command that has hung for 30 minutes, and hard-stops a run that blows its budget. |

None of these call a model. The budget is measured from Claude Code's own transcript files, not by asking Claude what it spent.

## Quickstart

You need [Claude Code](https://docs.claude.com/en/docs/claude-code), `tmux`, `git`, and `python3` (for the budget). macOS or Linux.

Install it as `stupid`, so you can type `stupid` in any folder:

```bash
brew install tmux          # or: sudo apt install tmux
mkdir -p ~/.local/share/stupid-simple-harness ~/.local/bin
curl -o ~/.local/share/stupid-simple-harness/stupid.sh https://raw.githubusercontent.com/A19grey/stupid-simple-harness/main/stupid.sh
chmod +x ~/.local/share/stupid-simple-harness/stupid.sh
ln -sf ~/.local/share/stupid-simple-harness/stupid.sh ~/.local/bin/stupid
stupid --version
```

If `stupid --version` says "command not found", add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` or `~/.bashrc` and open a new terminal. `stupid.sh` works through a symlink, and every run keeps its own snapshot in `.harness/`, so nothing else is needed. (Rather not install anything? Download `stupid.sh` into a folder and run `./stupid.sh` instead of `stupid`.)

Three ways to start:

```bash
stupid                                    # prints help, then asks for a folder and a prompt
stupid my-project                         # uses my-project/PROMPT.md if it exists, otherwise asks
stupid my-project "Do the thing"          # writes PROMPT.md and rips
```

While it runs:

```bash
stupid --status                 # every run: deadline, spend, kicks, nudges, restarts
stupid --attach my-project      # watch it work (Ctrl-b d to leave)
stupid --stop my-project        # stop for good
stupid --resume my-project      # restart from its last conversation
```

From inside a project folder, `.` works too: `stupid . "Fix the flaky tests" --hours 6 --budget 25`.

Want it for every user on the machine? `sudo ln -sf /path/to/stupid.sh /usr/local/bin/stupid` (on Apple Silicon Homebrew, `/opt/homebrew/bin` works too).

To update, re-run the `curl` line. To remove, delete `~/.local/bin/stupid` and the `~/.local/share/stupid-simple-harness` folder.

## Writing a good PROMPT.md

The harness keeps Claude working; the prompt decides whether that work is any good. Say what done looks like, then what "better" looks like, so there's something to do after v1:

```markdown
Build a small command-line tool that reads every CSV in ./data and writes report.html:
one summary table and two charts (rows per day, top 10 values of the busiest column).

Done for v1 when: `python3 report.py` runs on the sample data and report.html opens in a browser.
After v1: better charts, a short write-up of anything odd in the data, tests for messy CSVs.
Stay inside this folder. Do not install anything system-wide.
```

This one is in [`examples/PROMPT.md`](examples/PROMPT.md). Try it: `mkdir demo && cp examples/PROMPT.md demo/ && stupid demo --hours 1 --budget 5`

## Recipes

```bash
# A first run you can watch: one hour, five dollars
stupid demo --hours 1 --budget 5

# Overnight analysis on a cheaper model
stupid churn-analysis --until 07:00 --budget 30 -- --model sonnet --effort medium

# Fix flaky tests in a throwaway container, no permission prompts
stupid flaky-tests --hours 6 --budget 25 --yolo

# Three experiments at once, then check on all of them
stupid idea-a --until 07:00; stupid idea-b --until 07:00; stupid idea-c --until 07:00
stupid --status
```

Each `stupid` attaches you to its run; press **Ctrl-b d** to detach and start the next.

Driving hardware or slow network services? Say so in `PROMPT.md`. Claude is already told to wrap long commands in timeouts, and the watchdog presses Esc on anything stuck for 30 minutes, but a prompt that names the risky commands does better.

## Options

`stupid -h` (or `-help`, `--help`, `help`) prints all of these.

```bash
stupid my-project --hours 6                 # work for 6 hours (default 8)
stupid my-project --until 07:00             # ...or until a clock time
stupid my-project --budget 20               # spend limit in USD (default 50)
stupid my-project --yolo                    # no permission prompts (read the warning below)
stupid my-project -- --model sonnet --effort medium   # anything after -- goes to claude
```

Tuning knobs (environment variables): `SSH_IDLE_MIN` (15), `SSH_HANG_MIN` (30), `SSH_WATCH_EVERY` (600 s), `SSH_GRACE_MIN` (45, time allowed to wrap up after the deadline), `SSH_COMPACT_AT` (200000 tokens, when Claude Code auto-compacts).

## What happens in your folder

```
my-project/
  PROMPT.md        your task (the only file you write)
  PLAN.md          Claude's checklist; the harness counts the unticked boxes
  NOTES.md         decisions Claude made while nobody was awake
  SUMMARY.md       written at the end: what was built, how to try it, what's missing
  .harness/        harness state: config, log, rules, settings, a snapshot of stupid.sh
```

The folder becomes a git repo if it isn't one already, and `.harness/` is gitignored. Claude is told to commit after every step and never to push (`git push` is also denied in its settings).

Nothing is written to your global Claude Code settings. The harness passes its hook and rules at launch (`--settings` and `--append-system-prompt`), so they apply only to that run. Editing `stupid.sh` mid-run is safe: each run uses its own snapshot in `.harness/`.

## The budget

The harness reads Claude Code's transcripts (`~/.claude/projects/...`) and prices every model call at [API list prices](https://platform.claude.com/docs/en/about-claude/pricing), including subagents.

- **Under budget:** keep going.
- **At budget:** stop building, write `SUMMARY.md`, then stop.
- **At 1.25× budget:** hard stop. The session is closed and nothing restarts it.

Honest caveats:

- **On a Claude subscription,** the dollar figure is what the same usage would cost on the API. It still works as a usage limit, but it isn't your bill.
- **It can overshoot.** Spend is checked when Claude tries to stop and every 10 minutes, so one long turn can run past the limit before it's caught. The 1.25× hard stop is the backstop.
- **It only counts Claude Code.** Other agents you shell out to (Codex, OpenCode, ...) aren't included.
- **Prices change.** New models need a line in the price table in `stupid.sh`. An unknown model is priced like Opus 4.5, which errs on the high side.

## About `--yolo`

Without it, Claude runs in `acceptEdits` mode: file edits go through, but shell commands may stop and ask for approval. An approval prompt at 2 am waits until you wake up. The watchdog logs it but won't answer it.

With `--yolo`, Claude runs with `--dangerously-skip-permissions` and can run anything you can. Use it in a folder, VM or container where that's fine, with credentials you'd be OK losing control of for a night. Don't point it at production.

## FAQ

**Why not just a cron job that types "keep going"?**
Typing into a terminal while Claude is mid-turn is how you get garbage. The stop hook fires exactly when Claude stops, so it never interrupts work. The watchdog only types when the screen and the transcript have both been quiet for a while.

**Why does it keep working after the plan is done?**
Because you said "work until 7". Each time Claude says it's finished, the harness names a different way to raise the bar, Claude adds steps for it to the plan, and keeps going until the deadline or the budget.

**Won't it just make busywork?**
Sometimes. That's what the budget is for, and why the prompt should say what "better" means. Read `SUMMARY.md` and the git log, not the line count.

**Can I run several at once?**
Yes. One folder per run, one tmux session per folder (`stupid-<folder>`). `stupid --status` shows them all.

**My laptop went to sleep.**
On macOS the harness runs Claude under `caffeinate`, and on Linux under `systemd-inhibit` when it's available. Closing the lid still sleeps most laptops, so plug in and leave it open.

**Does it work on Windows?**
Use WSL.

## License

MIT. See [LICENSE](LICENSE).

Born during an overnight agent hackathon at a hardware team, out of frustration with agents that "finished" at 11:40 pm.
