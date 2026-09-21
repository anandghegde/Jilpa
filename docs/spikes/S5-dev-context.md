# Spike 5: developer context

2026-09-20 · Anand Hegde · status: process-table half done; the focused-window document URL read once on Ghostty (it picks one tab of seven), not yet labelled or followed across a tab switch; VS Code is not installed and stays an operator row

> Asked which VS Code and Terminal signals give the project root reliably. **The terminal half is a go, with a rule attached:** read the working directory of the tab's *job-control shell*, not of "the foreground process". That was right in 420 of 420 controlled trials over 21 shapes, including every shape where it must say unknown, and costs 0.23 ms at p95 with no permission at all. The literal reading (the foreground group's leader) named the wrong project in 3 of 21 shapes and the login shell in 2. The process table cannot say which tab the user is in, and the terminal device's timestamps cannot either; that still needs the focused window's document URL, which is not yet measured. Nothing is claimed about VS Code.

## Question

From the implementation plan: **Which VS Code and Terminal signals give the project root reliably? Does the narrow ambiguity definition in the architecture doc behave well with multi-root workspaces and several windows?**

Hypotheses this spike settles (architecture, Sensors, Dev context): VS Code's focused-window document URL **(H)**; Terminal's focused-window document URL tracking the shell's working directory **(H)**; the working directory of the tty's foreground process through `proc_pidinfo`, same-user, no entitlement **(H)**. And the Sensed project definition (architecture, Domain logic): freshness window of 2 hours (provisional), `unknown` for multi-root with no active document, `unknown` when two sources focused within a minute disagree.

Sharpened before starting:

1. "The tty's foreground process" is not one thing. A terminal tab has a login shell, perhaps nested shells, a foreground job, and the job may have changed directory by itself (`make -C`, a subshell). Which process's working directory is *the user's* working directory?
2. Which states must read `unknown` rather than a folder: the working directory was deleted; the foreground program is a remote or multiplexed session (`ssh`, `screen`, `tmux`) whose local directory says nothing; the process belongs to another user; the directory is not inside any project.
3. What does ascending to the project root cost, and what counts as a root: a `.git` directory, a `.git` file (worktree, submodule), the nearest or the outermost?
4. What does a lookup cost? The product samples on app activate, deactivate and focused-window change, never on a timer, so the budget is per event.

## Decision rule

Written on 2026-09-20, before the tool existed and before any data.

1. **A wrong folder is worse than none.** A signal is *primary* when, in controlled trials with a known truth, it names the right directory (same volume and file identifier) every time in the shapes it claims to support, and in every other shape the resolution layer says `unknown`. One trial that names a wrong project as known, in a shape the rule claims, sends that shape to the `unknown` list and the matrix is rerun. Supported shapes need at least 20 trials each; they are deterministic, so the count is about flakiness, not a rate.
2. **No new permission.** A signal that raises any consent prompt, needs an entitlement, or fails for ordinary same-user processes is out. Reading another user's process is expected to fail, and that must come out as `unknown`.
3. **Cost.** One resolution (process table scan, working directory, ascent to the root) at p95 under 10 ms, measured over at least 1,000 runs. Over that, the signal is sampled only on deactivate, not on every focused-window change.
4. **Root ascent never reads a repository.** It may `lstat` the name `.git` at each level and nothing else. It stops at the home directory, the volume root, or 40 levels. No root found means the working directory is offered as a plain folder only if the PRD wants that; by default it is `unknown` for N5 ("project root").
5. **Ranking.** Where two signals are both right in the same shapes, the one that needs no Accessibility read of another app's window wins as corroboration, and the AX document URL wins as primary only if it is right in shapes the process table cannot see (several tabs: which one is focused).
6. **VS Code.** Not installed on this Mac. Nothing about VS Code is claimed from here; its rows are operator rows, and the N5 launch promise stays gated on them.

**What needs the operator or the screen.** Terminal's and VS Code's AX document URL (on screen, real apps); which tab is focused when a window has several; staleness after the app deactivates; multi-root workspaces; the disagreement rule with both apps in use.

## Method

One throwaway tool, `Tools/spikes/s5-devcontext`, Foundation and Darwin only. It needs no Accessibility grant, opens no window and launches no app. The terminals under test are ptys the tool opens itself: `/usr/bin/script -q /dev/null /bin/zsh -f -i` with a pipe for a keyboard, which gives a real controlling terminal, a real interactive zsh with job control, and the same process shapes a terminal tab has. Every shell runs with a scratch `HOME`, so none of the owner's shell or `screen` configuration is read.

**What is read.** The process table through `sysctl(KERN_PROC_ALL)`: pid, parent, user, process group, the controlling terminal and *that terminal's foreground process group*, and the program name. A process's working directory through `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, which returns the directory vnode's current path and the vnode's own volume and file identifier. A shell's argument vector through `sysctl(KERN_PROCARGS2)`, used for one yes-or-no classification and never recorded.

**Three raw signals**, recorded side by side so the data can rank them:

| signal | which process's working directory |
| --- | --- |
| foreground group leader | the leader of the terminal's foreground process group: what "the tty's foreground process" means read literally |
| topmost shell | the shell on the tty with no shell above it: the login shell |
| job-control shell | from the foreground group's leader, walk up the parents on the same tty to the first shell *outside* the job's process group. A shell that leads the foreground group itself with no children in it is the prompt, if its arguments say it is interactive |

**The resolution under test** takes the job-control shell and says `unknown` when: any foreground program is a remote or multiplexed session (`ssh`, `mosh-client`, `screen`, `tmux` and a few more); a childless foreground shell's arguments are neither plainly interactive nor plainly a script; there is no shell; the shell belongs to another user; the read is refused; the directory has no name any more; or the path now names a different folder than the vnode (volume and file identifier compared). Then it ascends to the project root with one `lstat` of `.git` per level, stopping at the home directory, a volume boundary or 40 levels.

**Scenarios**, 20 trials each, a fresh tree of two projects, a worktree, a nested repository, a plain folder and a symlink per trial. Truth is an identity (volume and file identifier) taken by the tool, never a string.

| scenario | what the user did | truth |
| --- | --- | --- |
| idle, idle-after-cd | a prompt, in the start folder or after `cd` | that folder, its project |
| fg-job, fg-pipeline | `sleep`, `sleep \| cat` in the foreground | the shell's folder |
| fg-job-cd, fg-script-cd | a foreground job that changes directory by itself: `(cd B && sleep)`, `sh -c 'cd B; sleep; true'` | the shell's folder, not the job's |
| script-blocked | `sh -c 'cd B; read x'`: a childless shell leads the foreground, and it is not the prompt | the shell's folder |
| bg-job-cd | the same job in the background, prompt idle | the shell's folder |
| nested-shell, nested-shell-job | the user starts a second interactive zsh and changes directory in it, then runs a job | the inner shell's folder |
| nested-unclear | `bash --rcfile file`: interactive, but the arguments do not show it | `unknown` |
| symlink-cd | `cd` through a symlink into another project | the real folder |
| renamed-after-cd | the project is renamed under the shell | the renamed project |
| deleted, deleted-recreated | the shell's folder is removed; removed and made again at the same path | `unknown` |
| no-project, dotfiles-home | no `.git` above; a `.git` only in the (stand-in) home directory | the folder, no root |
| worktree, nested-repo | a `.git` file; a repository inside a repository | the nearest |
| screen | `/usr/bin/screen` in the foreground, its own socket directory | `unknown` |
| ssh-named | a program *named* `ssh` in the foreground. It is a copy of this tool that sleeps; nothing connects anywhere | `unknown` |

**Which tab.** The process table names a folder per tab but not the tab the user is in. One candidate needs no Accessibility read: the terminal device's last-read time, which `w` reports as idle time. Four shells at once; one is typed into; another prints 1.3 s later from a background job that either exits (its shell wakes and prompts again) or stays alive. 20 trials each way.

**Cost.** 2,000 resolutions against a shell six folders below its root with a job in the foreground, each part timed. Run while the spike 2 soak and the spike 6 matrix were also running, so this is a loaded machine, not a quiet one.

**Real terminals, read-only.** `s5-devcontext tree` walks the terminal apps that are running and prints, per tab, the foreground programs, whether the three signals agree, and the resolution with the path reduced to its depth. No path is printed or stored.

```bash
s5-devcontext selftest --trials 20 --out Tools/spikes/data/s5/selftest.jsonl
s5-devcontext latency --runs 2000 --out Tools/spikes/data/s5/latency.jsonl
s5-devcontext tree
s5-devcontext report Tools/spikes/data/s5/selftest.jsonl Tools/spikes/data/s5/latency.jsonl
```

**Not tested.** Terminal's and VS Code's AX document URL (needs the screen and the apps; VS Code is not installed). A real `ssh`, `tmux` or `mosh` session under test conditions: `tmux` is not installed, and the tool connects to nothing; one real `ssh` tab was seen by `tree`. A shell running as another user (`sudo -s`): needs a password; the refusal path is tested against pid 1 instead. Shells other than zsh, bash and the `sh` that macOS re-executes as bash. Terminal apps that host their shells outside their own process tree (a `tmux` server, a remote container). The freshness window and the two-sources-disagree rule, which need real use over days.

## Environment

| | |
| --- | --- |
| Mac | Apple M4, macOS 26.4.1 (25E253), APFS |
| Toolchain | Xcode 26.4.1 (17E202), Swift 6.3.1 |
| Shells | `/bin/zsh` 5.9, `/bin/bash` 3.2 (also what `/bin/sh` becomes), `/usr/bin/screen` 4.00.03 |
| Terminal apps installed | Ghostty, Terminal, Warp. **VS Code is not installed.** `tmux` is not installed |
| Permissions used | none: no Accessibility, no Full Disk Access, no prompt of any kind appeared |
| Load | spike 2 soak and spike 6 matrix running throughout |

## Results

Rule 1 (a wrong folder is worse than none): **met.** No trial named a wrong folder or a wrong root, no set-up failed, and every must-be-unknown shape read unknown for the expected reason. Rule 2 (no new permission): **met**; nothing prompted, and another user's process is refused (`EPERM`), which the resolution turns into unknown. Rule 3 (cost): **met** by a factor of about 40. Rule 4 (ascent): met by construction, and the home-directory stop and the nearest-wins choice behaved as written. Rules 5 and 6 are open: they need the on-screen half.

### The resolution against the truth

| scenario | n | set-up failed | expected | right | safe unknown | wrong reason | wrong root | **wrong known** | foreground | resolve ms p50 | p95 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| idle | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.41 | 0.53 |
| idle-after-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.47 | 0.54 |
| fg-job | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | sleep | 0.62 | 0.97 |
| fg-pipeline | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | cat+sleep | 0.64 | 1.61 |
| fg-job-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | sleep | 0.68 | 2.12 |
| fg-script-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | bash+sleep | 0.66 | 0.99 |
| script-blocked | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | bash | 0.70 | 2.26 |
| bg-job-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.42 | 0.51 |
| nested-shell | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.52 | 1.20 |
| nested-shell-job | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | sleep | 0.62 | 0.88 |
| nested-unclear | 20 | 0 | unknown:ambiguous-shell | 20 | 0 | 0 | 0 | 0 | bash | 0.42 | 0.62 |
| symlink-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.45 | 0.57 |
| renamed-after-cd | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.39 | 0.51 |
| deleted | 20 | 0 | unknown:directory-gone | 20 | 0 | 0 | 0 | 0 | zsh | 0.38 | 0.49 |
| deleted-recreated | 20 | 0 | unknown:directory-replaced | 20 | 0 | 0 | 0 | 0 | zsh | 0.39 | 0.48 |
| no-project | 20 | 0 | known-no-root | 20 | 0 | 0 | 0 | 0 | zsh | 0.50 | 0.73 |
| dotfiles-home | 20 | 0 | known-no-root | 20 | 0 | 0 | 0 | 0 | zsh | 0.41 | 0.71 |
| worktree | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.43 | 0.54 |
| nested-repo | 20 | 0 | known | 20 | 0 | 0 | 0 | 0 | zsh | 0.41 | 0.53 |
| screen | 20 | 0 | unknown:foreground-is-screen | 20 | 0 | 0 | 0 | 0 | screen | 0.52 | 0.62 |
| ssh-named | 20 | 0 | unknown:foreground-is-ssh | 20 | 0 | 0 | 0 | 0 | ssh | 0.53 | 0.71 |

### The three signals, read raw (right / wrong / none)

In rows where the expected answer is unknown there is no right folder, so any folder a raw signal offers counts as wrong. That is the point of those rows: a raw signal with no resolution layer over it would have offered one.

| scenario | foreground group leader | topmost shell on the tty | job-control shell |
| --- | --- | --- | --- |
| idle | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| idle-after-cd | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| fg-job | 20 / 0 / 0 (sleep) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| fg-pipeline | 20 / 0 / 0 (sleep) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| fg-job-cd | 0 / 20 / 0 (sleep) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| fg-script-cd | 0 / 20 / 0 (bash) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| script-blocked | 0 / 20 / 0 (bash) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| bg-job-cd | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| nested-shell | 20 / 0 / 0 (zsh) | 0 / 20 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| nested-shell-job | 20 / 0 / 0 (sleep) | 0 / 20 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| nested-unclear | 0 / 20 / 0 (bash) | 0 / 20 / 0 (zsh) | 0 / 0 / 20 |
| symlink-cd | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| renamed-after-cd | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| deleted | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) |
| deleted-recreated | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) |
| no-project | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| dotfiles-home | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| worktree | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| nested-repo | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) | 20 / 0 / 0 (zsh) |
| screen | 0 / 20 / 0 (screen) | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) |
| ssh-named | 0 / 20 / 0 (ssh) | 0 / 20 / 0 (zsh) | 0 / 20 / 0 (zsh) |

### Which tab was typed into last

| what the other tab's job does | trials | tabs | newest terminal read time is the typed tab | newest terminal write time is the typed tab | newest write time is the tab that printed later |
| --- | --- | --- | --- | --- | --- |
| job-exits | 20 | 4 | 8 | 8 | 12 |
| job-stays | 20 | 4 | 20 | 7 | 13 |

### Cost of one resolution (2000 runs, 628 processes, root 6 levels up)

| part | p50 ms | p95 ms | max ms |
| --- | --- | --- | --- |
| directory and root | 0.033 | 0.039 | 0.733 |
| one resolution | 0.214 | 0.230 | 1.180 |
| pick the shell | 0.040 | 0.046 | 0.128 |
| table for one tty | 0.033 | 0.038 | 0.311 |
| whole table | 0.139 | 0.148 | 0.458 |

Another user's process (pid 1): refused, errno 1.


### Real terminals, read once, paths reduced to depth

`s5-devcontext tree` on this Mac's running Ghostty (seven tabs; Terminal and Warp were not running):

| tabs | foreground | the three signals | resolution |
| --- | --- | --- | --- |
| 5 | a long-running CLI with 16 to 19 processes in its foreground group | all agree | known, root found |
| 1 | the same | all agree | known, no root above it: `unknown` for N5 |
| 1 | a real `ssh` session | all agree, on the local folder the session was started from | `unknown: foreground-is-ssh` |

Per tab the pick and the directory read took 0.01 to 0.19 ms once the table was in hand.

### The focused window's document, read once from the real terminal (`focused`)

Read-only, two Accessibility attributes (`AXFocusedWindow`, then `AXDocument`), the path shown as depth only and stored nowhere.

| App | Tabs | Known / unknown by the process table | Distinct roots | Windows, with a document | Focused document | Matches by identity | Which-tab rule says | Cost, 20 reads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Ghostty, the owner's session | 7 in one window | 6 / 1 (the `ssh` tab) | 5 | 1, 1 | file URL, depth 4 | 1 of 6 | known: one tab, root found | p50 0.03 ms, p95 0.06 ms |

Ghostty does publish a document URL on its window, it is a file URL, and it named exactly one of the six per-tab candidates by identity, not the tab this tool ran from. That is the rule working in the case it was written for: five different roots open at once, one answer. **What this one read does not show** is that the named tab was the tab the owner had in front (nobody labelled it), that the URL follows a tab switch and a `cd`, or what Terminal and Warp publish. Those stay open rows.

### Surprises

1. **"The tty's foreground process" is the wrong words.** A foreground job that changes directory by itself (`make -C`, a subshell, a script) makes the foreground group's leader point at another project: wrong in 60 of 60 trials across three shapes. The login shell is wrong whenever the user has started a second shell: 40 of 40. The shell that owns job control for the foreground group was right in all of them.
2. **A childless shell in the foreground is not always the prompt.** A script sitting in `read` looks exactly like an idle prompt in the process table: a shell, leading the foreground group, no children. Only the argument vector separates them, and `bash --rcfile file` cannot be classified from arguments, so it reads unknown. This needs `KERN_PROCARGS2`, which works for same-user processes without any permission. The arguments are classified and dropped.
3. **`/bin/sh` is called `bash` in the process table**, since macOS's `sh` re-executes itself. **A symlink does not rename a program** either: the table shows the name of the file that ran. And a *copy* of `/bin/sleep` under another name is killed at launch (exit 137); copied platform binaries do not run. The `ssh` stand-in had to be a copy of the spike tool.
4. **A deleted working directory still has a path.** `proc_pidinfo` returned the old path in 40 of 40 trials after the folder was removed, never an empty one. If a new folder has been made at that path, a string-based reader would walk straight into it, and in the test tree would have found a project root above it. The vnode's volume and file identifier, which the same call returns, do not match the newcomer's, and that comparison is what made `deleted-recreated` read unknown. Folder equality by identity, again.
5. **The terminal device's timestamps do not say where the user typed.** The read time (what `w` shows as idle) named the typed tab in 20 of 20 trials while the other tab's job kept running, and in 8 of 20 once that job exited: a shell that wakes to print a prompt starts a new read, and the kernel stamps the read time when a read *starts*, not when a key arrives. The write time was no better than a coin. A background build finishing would steal the "last typed" tab. **Dropped**, under rule 1.
6. **A long-running CLI puts 16 to 19 processes in one foreground group.** The pick is by group leader and parent chain, so the count does not matter, but anything that scanned "the foreground process" as a single pid would be choosing among them arbitrarily.
7. **The whole process table costs 0.14 ms** (628 processes). There is no reason to be clever with the per-tty query; one scan serves every tab of every terminal app.

## Decision

**Go for the process-table signal, as a supplier of candidates per tab; not yet as the answer to "the active project".**

1. The Terminal fallback row in the architecture becomes a real signal with a precise definition: **the working directory of the job-control shell of the tab's tty**, checked by vnode identity, then ascended to the nearest `.git`. It says `unknown` for a remote or multiplexed foreground program, an unclassifiable childless shell, another user's shell, a refused read, a directory that is gone or replaced, and no root below the home directory.
2. It is sampled on the events the architecture already names (app deactivate, focused-window change). At 0.23 ms it needs no throttling and no caching.
3. **Which tab is the open question, and the process table cannot close it.** Proposed rule for the on-screen half to confirm: when every tab of the frontmost terminal app resolves to the same root, that root is known whatever the focused tab is. When tabs differ, the focused window's document URL picks one, and it counts only if it matches one of the process-table candidates by identity. No match, or no document URL, is `unknown`. This keeps "several open repos is not by itself ambiguous" for windows while refusing to guess among tabs.
4. The terminal device's timestamps are not used for anything.
5. `tmux` users read `unknown`: the panes' shells belong to the tmux server, not to the terminal app's process tree. That is a known gap, stated in the health view, not a bug to work around in M1.

**Still open, and who closes it.**

| open | how | who |
| --- | --- | --- |
| Terminal's focused-window document URL: does it track `cd`, per tab, with the default shell integration, and in Ghostty and Warp? | a small AX reader against Terminal and Ghostty with scratch folders | me, when the screen is free |
| The which-tab rule in point 3 | the same run | me |
| VS Code: focused-window document URL, `storage.json`, multi-root with no active document | needs VS Code installed | owner decides whether to install it; otherwise an operator with VS Code |
| The 2-hour freshness window and the two-sources-disagree rule | days of real use; shadow-logged in the alpha, not a spike | alpha |
| A shell running as another user (`sudo -s`) | needs a password | operator; expected `unknown`, refusal path already shown on pid 1 |

## Architecture impact

| Where | Change |
| --- | --- |
| Sensors, Dev context, Terminal fallback row | "Working directory of the tty's foreground process" → "working directory of the tab's job-control shell (process table, `proc_pidinfo`), checked by vnode identity". Hypothesis mark removed for the no-entitlement claim; ranking against the document URL stays open |
| Sensors, Dev context, new paragraph | The unknown list above; the argument-vector classification and the promise that arguments are never stored; `tmux` as a declared gap |
| Domain logic, Sensed project | Adds the which-tab rule as **(H, spike 5 on-screen half)** |
| Privacy pane disclosure | One line owed when this ships: "reads the list of running programs and the current folder of your terminal shells; never their arguments, output or history" |

## What is kept

Nothing from the tool's code. Kept as knowledge: the job-control-shell rule and its unknown list, the identity check on the working directory, the scenario list as the seed of the sensor's unit tests (the pick is a pure function over a process list and is testable without a pty), and the pty harness idea for an integration test.

## Raw data

`Tools/spikes/data/s5/selftest.jsonl` (420 trial records and 40 tab records) and `latency.jsonl`, both ignored by git. Records hold scenario names, program names and outcomes; no paths. The `tree` reading of real terminals was printed to the terminal only, with paths reduced to depth, and stored nowhere.

`s5-devcontext report Tools/spikes/data/s5/selftest.jsonl Tools/spikes/data/s5/latency.jsonl` reproduces the tables above.
