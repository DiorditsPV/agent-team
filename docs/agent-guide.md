# agent-team: setup and operation guide

This guide takes you from a clean machine to a running team and back: install `team`, describe the team in your project's `agents/` directory, start it in tmux, give the manager its first task, replace a role's session, and stop the team. It is written so that you can follow it yourself or hand it to Claude Code as a task.

What this guide does not cover:

- The full role-file format and design decisions. They are in [`SPEC.md`](SPEC.md) (in Russian); the fields you need to edit are listed in step 5.
- Which roles to pick. Ready roles and advice on when to use each are in the [role library](../roles/README.md) (in Russian).
- The macOS desktop app that shows the team in one window. How to build it is in the [README](../README.md#desktop-app); how it works and what it costs the CPU is in [`app.md`](app.md).

`team` prints its messages in Russian. Every expected output below is quoted exactly, with a translation after it.

**If you are an agent following this guide,** stop and ask the user at each of these points:

- step 2 — whether to install `team` globally or call it through `uv run`;
- step 5 — which roles the team gets, their zones and models: propose them as a table and write role files only after the user agrees;
- step 5 — whether to commit `agents/` to the project;
- step 8 — the folder-trust prompt, and any permission prompt you see in a role's pane: only a human answers these;
- step 9 — what the manager's first task is, unless the user already told you.

Skip the interactive `team attach`: watch panes with `team peek <role>` instead.

## 1. Check the requirements

Run:

```bash
tmux -V
claude --version
uv --version
git --version
```

Expect a version line from each command. Then, in your project, run `git rev-parse --show-toplevel` and expect the project's root path: roles that edit files work in git worktrees, so the project must be a git repository. You also need to be signed in to Claude Code: running `claude` must open a session, not a sign-in screen. uv provides Python 3.10 or newer for `team`.

If a command is missing, install it before going further: `team` cannot start a team without tmux and `claude`.

## 2. Install `team`

Clone the repository into any directory outside your project and run:

```bash
git clone https://github.com/DiorditsPV/agent-team
cd agent-team
uv tool install --editable .
command -v team
```

Expect `command -v team` to print a path. To remove the command later, run `uv tool uninstall agent-team`.

If you prefer not to install anything globally, skip `uv tool install` and replace `team` in every command below with `uv run --project <path to the clone> team`, run from your project directory.

## 3. Connect the `/a-team` skill (optional)

The `/a-team` skill lets a regular Claude Code session do steps 4–9 for you: in your project, type `/a-team`. To connect it, run from the clone directory:

```bash
mkdir -p ~/.claude/skills
ln -s "$PWD/skill/a-team" ~/.claude/skills/a-team
ls ~/.claude/skills/a-team/SKILL.md
```

Run these from the clone directory, because the link uses `$PWD`. Expect `ls` to print the path to `SKILL.md`. The skill's instructions are written in Russian.

## 4. Create `agents/` in your project

`team` looks for `agents/team.yaml` in the current directory and its parents, so run every command from inside your project. Run:

```bash
cd <your project>
team init
```

Expect:

```
создан agents/roles/executor.md
создан agents/roles/manager.md
создан agents/team.yaml
создан agents/templates/task-assignment.md
Дальше: отредактируйте agents/roles/*.md под проект, затем team check и team up.
```

The lines say: "created …" for each file, then "Next: edit agents/roles/*.md for the project, then team check and team up."

If `agents/team.yaml` already exists, `team init` stops with an error and overwrites nothing.

## 5. Edit `agents/` for your project

The directory holds four kinds of files:

- `agents/team.yaml` — who is on the team and how it starts;
- `agents/roles/<role>.md` — one file per role: settings in the frontmatter, the agent's instruction in the body;
- `agents/shared/*.md` — rules shared by several roles. `team init` creates none: a role's `includes` are found in the library unless you add a file of the same name here;
- `agents/templates/task-assignment.md` — the message template for assigning a task.

Edit `agents/team.yaml`:

| Field           | What to set                                                                                                                                                    |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `project`       | Project name; the tmux session is called `team-<project>`.                                                                                                     |
| `repo`          | Optional. The main repository; the manager runs there and `.team/` is kept there. Defaults to the directory that holds `agents/`.                              |
| `layout`        | `panes` — all roles in one window, manager on the left; `windows` — a window per role. `team init` writes `panes`; if the field is missing, `windows` applies. |
| `tracker`       | Optional. Your tracker, either a label such as `Linear DEMO` or a mapping with fields of your choice such as `{kind: linear, project: DEMO}`. `team status --json` prints it as a string or an object; `team` never contacts the tracker. |
| `worktree_root` | Where role worktrees are created; a relative path counts from `repo`. The directory may lie inside the repository (for example `.claude/worktrees`): `team` then excludes the main directory's `CLAUDE.md` files from the role's brief.                                                                                          |
| `test_command`  | The project's test command, for example `uv run pytest`. Its first word is added to every role's allowed tools.                                                |
| `manager`       | The name of the manager role.                                                                                                                                  |
| `roles` | The list of roles, each with a `start` value (below). |
| `idle_stop_minutes` | Optional. A whole number of minutes above zero, or `off`. `team reap` stops agents of `start: on_demand` roles that sit idle this long (see "Stop idle agents"). Without the key (or with an empty value) the threshold is 15 minutes; `off` turns auto-stop off. |
| `defaults` | Optional. Launch fields shared by all roles: `mcp`, `plugins`, `settings`, `chrome`, `env`, `context` (see "Keep a role's start light"). |
| `mcp_servers` | Optional. Definitions of MCP servers by name, written as in `.mcp.json`; a role picks them with `mcp`. |

The `start` value tells when a role is started:

- `manual` — the manager; `team up` starts it;
- `always` — started by `team up` together with the manager;
- `on_demand` and `per_task` — the manager starts the role itself when a task needs it;
- `proposed` — described but not in use yet.

`manual` means that nothing starts the role on its own except `team up`, which always starts the manager. The role named in the `manager` field is the manager; its file must say `kind: manager`, or `team check` reports an error.

The scaffold `team.yaml` looks like this:

```yaml
project: myproj
repo: /path/to/myproj
layout: panes
worktree_root: ../myproj-wt
test_command: ""               # for example: uv run pytest

manager: manager

roles:
  - role: manager
    start: manual
  - role: executor
    start: on_demand
```

Edit each role file in `agents/roles/`. The scaffold executor starts like this; the instruction to the agent follows the second `---`:

```yaml
---
role: executor
title: Исполнитель
kind: executor
status: draft
description: "Выполняет задачи менеджера в своём worktree"
model: sonnet
worktree: {dir: executor, branch: executor}
zone: []
includes: [reporting.md]
---
```

The frontmatter fields:

| Field         | What to set                                                                                                                                                                                                    |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `role`        | The role name; it matches the file name and the entry in `team.yaml`.                                                                                                                                          |
| `title`       | The Claude Code session name.                                                                                                                                                                                  |
| `kind`        | `manager`, `executor`, `reviewer` or `watcher`. Only `manager` changes behaviour: it gets the `team` commands.                                                                                                 |
| `status`      | `active`, `draft` or `proposed` (a role described but not yet tried in real work). `team check` warns about `draft`. |
| `description` | One line about the role, in quotes: an unquoted `: ` breaks the YAML.                                                                                                                                          |
| `model`       | The Claude model, for example `opus` or `sonnet`; `inherit` or empty uses the default.                                                                                                                         |
| `worktree`    | `{dir, branch}` for a role that edits files, `null` otherwise. The worktree is created at `<worktree_root>/<dir>` on `branch` the first time the role starts. Add `repo`, a path from the main repository, to create it from another repository. |
| `zone`        | Files and directories only this role edits. `team check` warns when two roles list the same entry. The tool adds it to the role's instruction as a «Zone» section, so do not repeat it in the body; a role without a zone is told that the manager's task names the files.                                          |
| `tracker_zone` | The zone's label in the tracker; the tool adds it to the «Zone» section of the instruction. |
| `includes`    | File names from `agents/shared/`, for example `[reporting.md]`, appended to the role's instruction. A file missing from `agents/shared/` is taken from the library's `roles/shared/`. |
| `allow`       | Tools beyond the default set, in Claude Code `--allowedTools` syntax, for example `Bash(ruff *)` for a linter or a tracker's MCP tools. |
| `extends`     | A shared role from the library to inherit: its body and fields come first, this file adds the project notes. Rules: `docs/SPEC.md`, «Наследование общей роли». |
| `add_dirs`    | Extra directories the role may access.                                                                                                                                                                         |

Every role may use `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Bash(git *)` and `Bash(<first word of test_command> *)` without asking; the manager also gets `Bash(team *)`. Add anything else through `allow`.

You can also change roles from the command line instead of editing files. Both commands keep the role body and the comments in `team.yaml` untouched and print the role as JSON:

- `team role set <role> [--title …] [--model opus|sonnet|haiku] [--description …] [--start manual|always|on_demand] [--extends <shared role>]` changes these fields of an existing role; `--extends ""` removes inheritance;
- `team role new <role> --title … [--model …] [--description …] [--start …]` creates an executor role: a role file with `worktree: {dir: <role>, branch: team/<role>}`, the `includes` of the first executor role, and a one-line body to replace with the real instruction. `start` defaults to `on_demand`. The name must match `^[a-z][a-z0-9_-]*$`;
- `team role new <role> --extends <shared role> [--start …]` creates a thin role that inherits a shared role from the library: `extends`, `zone: []`, its own worktree if the shared role has one, and a comment in place of the project notes. `--title` is optional, `start` defaults to `manual`.

Then:

1. Set `status: active` on the scaffold `executor` role, or replace it with shared roles from the [role library](../roles/README.md). Do not copy a shared role: inherit it with `team role new <role> --extends <shared role>`, then replace the comment in the body with the project notes, including the values of the shared role's `<…>` placeholders. The scaffold `manager.md` already inherits the shared manager. The role library lists what to write in the notes.
2. Give each file-editing role its own `worktree` and a zone that no other role shares.
3. Add `.team/` to the project's `.gitignore`: it holds the team's state cache and the assembled instructions.
4. Ask the user whether to commit `agents/`. Commit only with their consent.

## 6. Check the description

Run:

```bash
team check
```

`team check` starts no agents. It prints a line per problem — `предупреждение:` (warning) or `ошибка:` (error) — and ends with a summary. On the untouched scaffold, expect:

```
предупреждение: executor: роль-черновик (status: draft)
роли: manager, executor; ошибок 0, предупреждений 1
```

That is: "warning: executor: draft role", then "roles: manager, executor; errors 0, warnings 1". After your edits the role list and the warnings differ: read each warning. Continue when the summary says `ошибок 0` (errors 0); the command then exits with code 0. With errors it exits with code 1: fix each `ошибка:` line and run it again.

## 7. Start the team and attach

Run:

```bash
team up
```

Expect one line per started role, then the attach hint:

```
manager#1: запущена, панель %0 в tmux-сессии team-<project> (<directory>)
Подключиться: team attach   (tmux-сессия team-<project>)
```

That is: "manager#1: started, pane %0 in tmux session team-<project>", then "Attach: team attach". `#1` is the agent number: a role can run several agents, see step 10. The pane number varies. `team up` starts the manager and every role with `start: always`; with the scaffold, that is the manager alone.

Then run `team attach` if you are a human; an agent skips it and uses `team peek manager 30`. `team attach` opens the tmux session on the manager's pane; `team attach <role>` opens it on that role's pane.

tmux keys (prefix `Ctrl-b`):

- `Ctrl-b` then an arrow key — move to the neighbouring pane;
- `Ctrl-b z` — zoom the current pane in or out;
- `Ctrl-b d` — detach from tmux; the agents keep working.

Do not close a pane with `exit`: that stops its agent.

## 8. Answer the folder-trust prompt

In a directory where `claude` has never run, it asks whether you trust the folder. The question appears once for the manager and once for each new worktree, including the worktree of each extra agent `<role>#<n>`, and the role waits in its pane until a human answers.

To find it, run `team peek <role> 30` and look for "Do you trust this folder" or "Quick safety check". To answer, run `team attach <role>`, choose "Yes, I trust this folder", and press `Ctrl-b d` to detach.

`team` never answers this prompt for you, and neither should an agent following this guide: trusting a folder is the user's decision.

## 9. Send the manager its first message

The manager in tmux is a new session with an empty context. It knows only its role file, the tracker and the repository. Give it either a first task or a handover of current work:

- tasks in progress and their status;
- branches and worktrees with unfinished work;
- decisions already made that are not written down anywhere;
- what is waiting for your decision.

How to send it:

- a human types the message into the manager's pane;
- an agent in a Claude Code session sends it with `SendMessage` to the address from `team addr manager`. If there is no address, ask the user before using `team send manager --paste`: pasted text looks to the manager like the user's own words.

Done when `team peek manager` shows the manager working on the message. The `/a-team` skill collects the handover from your current conversation and sends it for you.

## 10. Work through the manager

From now on you talk only to the manager. It runs the `team` commands itself:

1. The manager starts a role for a task: `team spawn <role>`.
2. The manager sends the task with `SendMessage` to the role's address from `team addr <role>`. The address is a socket (`uds:…`), not a session name, for two reasons: session names can repeat, and a message sent to the socket reaches the role marked as coming from the manager, not as typed by the user.
3. The role works in its worktree and reports back to the manager.
4. The manager accepts the work by the commit and the test output, then merges. When to merge and with whose consent is set in the manager's role file; the library manager merges only what you named.
5. When a role's work is done, the manager stops it: `team down <role>`.

To look without interfering, run `team status` (agents, state, how long each has been quiet, `SendMessage` address) or `team peek <role>` (the last 40 lines of the role's pane).

### Several agents of one role

A running session of a role is an *agent*, named `<role>#<n>`. To work on two tasks with one role at once, the manager runs `team spawn <role>` again:

- `team spawn <role>` starts the agent with the lowest free number; `team spawn <role>#<n>` starts that exact agent;
- agent `#1` works in the role's worktree `<worktree_root>/<dir>` on `branch`; agent `#n` gets its own worktree `<worktree_root>/<dir>-<n>` on branch `<branch>-<n>`, so two agents never edit the same directory;
- `addr`, `peek`, `send`, `handoff`, `restart`, `down` and `attach` accept `<role>#<n>`; a plain role name means `#1`.

### The event log

`team` keeps a log of what happened in `.team/events.jsonl`. It writes `spawn`, `restart`, `down` and `handoff` events itself. The manager or a script adds `task`, `report`, `commit`, `waiting` and `owner` events:

```bash
team log task developer "took DEMO-12" --task DEMO-12
team events --limit 5
```

A plain role name in `team log` is recorded as `#1`: write `developer#2` for the second agent. `team events` prints the newest events first; `--since <unix time>` keeps events from that moment on.

The manager also names each agent's current task for you, so that `team status` shows what an agent is doing in plain words rather than a tracker number:

```bash
team task developer "Weekly sales report" --id DEMO-12
team task developer --clear
```

The title must be 8–48 characters long, on one line, and must not be a bare task number, a path, a file name or text in backticks; otherwise `team task` exits with code 1 and lists what to fix. `team down` and `team restart --fresh` clear the title.

## Commands

Run `team` with no arguments to print a short version of this workflow.

| Command                           | What it does                                                                                                                             |
|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `team`                            | Prints the workflow.                                                                                                                     |
| `team --version` | Prints `team <version>`, or `team unknown` when the package is not installed. Works outside a project. |
| `team init`                       | Creates `agents/` in the current directory; never overwrites an existing `team.yaml`.                                                    |
| `team check [--json]` | Checks the team description without starting agents: tmux and `claude`, roles, included files, launch fields, manager `kind`, unknown `kind` values, worktrees, zone overlaps. |
| `team up [--resume]`              | Starts the manager and roles with `start: always`; `--resume` continues their previous sessions.                                         |
| `team spawn <role> [--resume]`    | Starts the role's next free agent; `<role>#<n>` starts that agent.                                                                       |
| `team status [--json]` | Lists agents: state (`работает`, `простаивает`, `ждёт ответа`, `ждёт: доверие`, `нет данных`, or `! в фоне` / `! чужой процесс` / `! без роли` when the pane is not the role's session), how long each has been quiet, context size in the `ctx` column, the title of the current task, and the `SendMessage` address. |
| `team roles [--json]`             | Lists roles: kind, start mode, number of running agents, title.                                                                          |
| `team role set <role> …`          | Changes a role's title, model, description or start mode (step 5).                                                                      |
| `team role new <role> --title …`  | Creates an executor role (step 5).                                                                                                       |
| `team addr <agent>`               | Prints the agent's address (`uds:…`) for `SendMessage`.                                                                                  |
| `team peek <agent> [lines]`       | Prints the last lines of the agent's pane; 40 by default.                                                                                |
| `team attach [agent]`             | Attaches to tmux; to the manager's pane by default.                                                                                      |
| `team handoff <agent> [--task X] [--reason …] [--paste] [--force]` | Creates a handoff file and prints the address and the request to send; with `--paste`, types the request into the agent's input line. Refuses while the agent's worktree has uncommitted changes; `--force` overrides. For a role without its own worktree (`worktree: null`), untracked files in the project's agents directory and in `.claude/` do not count, while changes to tracked files still do. |
| `team handoffs [--json]`          | Lists handoff files, newest first, with their status.                                                                                    |
| `team restart <agent> [--fresh]` | Recreates the agent's session: resumes the current conversation (the one after `/clear`, if there was one), or with `--fresh` starts a new one, marks the last handoff `used` and prints the new session's address and the handoff path. |
| `team send <agent> --paste <text>` | Fallback: types text into the agent's input line; the agent takes it as the user's words.                                               |
| `team events [--json] [--since ts] [--limit n]` | Prints the event log, newest first.                                                                                         |
| `team log <type> <agent> <text> [--task X]` | Adds an event to the log.                                                                                                       |
| `team task <agent> ["<title>"] [--id N] [--clear]` | Sets the title of the agent's current task for you, clears it with `--clear`, or prints it when no title is given. |
| `team reap [--keep <agent>…] [--dry-run] [--json]` | Stops idle agents of `start: on_demand` roles after `idle_stop_minutes`. |
| `team set idle_stop_minutes <minutes\|off>` | Changes `idle_stop_minutes` in `team.yaml` (`off` writes the line `idle_stop_minutes: off`), leaving the rest of the file as it is. |
| `team down [agent]` | Stops one agent, or the whole team. |

`<agent>` is `<role>#<n>` or a role name, which means `#1`. Without `--paste`, `team send` delivers nothing: it fails and prints the agent's address for `SendMessage`.

## Machine-readable output

Scripts and other programs read the team's state through `--json`. `status`, `roles`, `check`, `events` and `handoffs` accept it; `role set` and `role new` always print JSON. Times are unix seconds, paths are absolute. The field-by-field contract is in [`SPEC.md`](SPEC.md), section «Машиночитаемый вывод» (in Russian); the main fields are:

- `team status --json` — an object with `project`, `repo`, `session`, `session_alive`, `tracker` and `agents`. Each agent has `name` (`<role>#<n>`), `role`, `n`, `title`, `kind`, `model` (`"inherit"` when the role sets none), `alive`, `pane_id`, `session_id` (the current conversation: after `/clear` it is the new session, not the one `team` launched), `launch_session_id` (the session `team` launched), `cwd`, `branch`, `started`, `idle_s`, `waiting_human`, `addr`, `task`, `task_title` and `task_ts` (the number, title and time of the agent's current task, from its latest `task` event; `null` when there is none or it was cleared), `task_cleared_ts`, `state` (`busy`, `idle`, `waiting` or `null`), `question`, `role_check`, `ctx`, `compactions`, `ctx_limits`, `reset_due`, `reset_ready`, `reset_blockers`, `context_warning` and `dirty` (uncommitted paths in `cwd`, or `null` outside git). A role with no pane is listed once as `#1` with `alive: false`. For an agent that is not alive, `started` and `idle_s` are `null`; `cwd` comes from its last run or, if it never ran, from the plan, and `branch` is read from git in `cwd` or taken from the plan.
- `team roles --json` — a list of roles with their frontmatter fields, `start`, `file`, `worktree`, the final `effective_allow` tool list, `running` (live agents), `body` and the assembled `instruction`. A role whose file cannot be read has an `error` field instead.
- `team check --json` — `{passed, issues}`: `issues` lists every check as `{level, title, detail}` with `level` `error`, `warn` or `ok`; `passed` counts the `ok` ones.
- `team events --json` — a list of `{ts, type, agent, text, task}`, newest first.
- `team handoffs --json` — a list of handoffs with `id` (the file name without `.md`), `agent`, `ts`, `task`, `reason`, `status` (`waiting` or `used`), `used_at` (when `team restart --fresh` marked it `used`, otherwise `null`), `branch`, `worktree` and `sections` — the text of the five sections.

On success the exit code is 0. Errors are not JSON: `team` prints `team: <message>` to stderr and exits with code 1 (code 2 for a malformed command line). `check --json` is the exception: it prints JSON even when it finds errors, and exits with code 1.

## Keep a role's start light

A role starts with every MCP server, plugin and connector you have enabled, even if it uses none of them; in one project this was 73–76 thousand tokens, about 46 thousand of them unused tools. Launch fields trim this. They go in a role file, in a shared role, or once for everyone in `defaults` in `team.yaml`; the order is `defaults`, shared role, project role.

```yaml
# agents/team.yaml
defaults:
  chrome: false              # start roles with --no-chrome
  mcp: [linear]              # only this server
mcp_servers:
  linear: {type: http, url: "https://mcp.linear.app/mcp"}
```

```yaml
# agents/roles/reviewer.md, frontmatter
mcp: []                      # this role gets no MCP servers
plugins: {off: [some-plugin]}
```

- `mcp` and `chrome` replace the value from the earlier layer; `plugins`, `settings`, `env` and `context` merge by key.
- `mcp` is a list of server names. A name is looked up in `mcp_servers`, then in `~/.claude.json`, then in the project's `.mcp.json`. `team` writes the chosen servers to `.team/build/<agent>-mcp.json` (mode 0600, because definitions can hold tokens) and starts the role with only those. An unknown name is an error in `team check`.
- `plugins` is `{off: [names]}` or `{only: [names]}`.
- `settings` adds Claude Code settings. The keys that `team` sets itself or that control permissions are ignored, and `team check` warns about them.
- `env` adds environment variables; names that `team` sets itself are ignored.

Run `team check` after editing. The exact rules are in `docs/SPEC.md`, «Запуск роли: MCP, плагины, настройки».

## Watch the context size

`team status` shows each agent's context in thousands of tokens. `сброс` next to it means the agent is idle and above the `soft` limit (250k by default): start a fresh session before the next task. `сброс*` means the same, but something blocks it (an uncommitted change, a dialog open in the pane, a pane that is not the role's session); the reason is printed under the table. `!` means a working agent is above `warn` (400k). Change the limits with `context: {soft, warn, hard}` in a role or in `defaults`; `hard` is also the window at which Claude Code compacts the context. The manager does the reset between tasks: handoff, `team restart <role> --fresh`, then the next task. A reply in the middle of a task is not a task boundary.

## Stop idle agents

An on-demand role stays open after its task and holds context and a place in tmux. Without a setting, `team reap` stops agents idle for 15 minutes; set `idle_stop_minutes: 10` in `team.yaml` (or run `team set idle_stop_minutes 10`) to change that, or `off` to turn auto-stop off. Call `team reap` periodically; the desktop app calls it every minute for every project whose team has a live tmux session, open in the app or not. Without a threshold, on-demand agents sat idle for hours and Claude Code compacted their context without a turn, spending the limit. `team reap --dry-run` shows what would be stopped. `team reap` keeps:

- the manager and roles whose `start` is not `on_demand`;
- an agent named in `--keep`, a working agent, or one waiting for an answer;
- an agent that still has a task: clear it with `team task <agent> --clear` when you accept the work;
- an agent with a dialog open or text typed in its input line;
- an agent whose pane is not the role's session.

Idle time counts from the later of the agent's last activity and the moment its task was cleared.

## Replace a role's session

Replace a session when its context grows past its limit (`сброс` in the `ctx` column of `team status`), it has crashed, or the role must restart with a changed instruction. The manager usually does this; you can ask it to. The handoff command refuses while the agent's worktree has uncommitted changes: ask the role to commit or set them aside first, or add `--force`.

1. Run `team handoff <role> --task <task ID> --reason "<why>"`; both flags are optional. It creates the handoff file `.team/handoffs/<time>-<role>#<n>.md` with five empty sections: «Сделано» (done), «Проверено» (verified), «В работе» (in progress), «Подводные камни» (pitfalls), «Дальше» (next). Then it prints the agent's address and a request text that names the file. From a Claude Code session, send that text with `SendMessage` to the address. From a plain shell, run `team handoff <role> --paste` instead, which types the request into the agent's input line. The request asks the agent to fill in the file, post the summary to the tracker task, commit or list uncommitted changes, and then do nothing more; the agent stays open. If no address is found, the command fails with code 1 after creating the file. Then run `team handoff <role> --paste`. While the agent's latest handoff is still `waiting` and empty, a repeated `team handoff` writes to that same file and refreshes its header; once a section is filled in or the handoff is `used`, it creates a new file.
2. Run `team handoffs --json`. Continue when the newest entry for the agent has its `sections` filled in. Check the file, not the agent's pane.
3. Run `team restart <role>` to continue the same session, or `team restart <role> --fresh` to start a new one. `--fresh` marks the agent's latest handoff `used`. The new session does not read the file by itself: send it the file path together with its task.

If the whole team was stopped with `team down`, run `team up --resume`: it brings back the manager and the roles with `start: always` with their previous sessions. Bring back any other agent with `team spawn <agent> --resume`.

## Stop

1. For each role with unfinished work — uncommitted changes, a task in progress — request a handoff first (previous section).
2. Run `team down <role>` to stop one role, or `team down` to stop the whole team.
3. Run `team status`. Expect `не запущена` (not running) for every stopped role.

## Known limitations

- A new directory triggers the folder-trust prompt, and the role waits until a human answers in its pane (`team attach <role>`).
- `team` does not set a permission mode: roles inherit your Claude Code default (`permissions.defaultMode`). If that mode asks before running a tool outside the role's list, the role waits for a human in its pane.
- `team status` takes `busy`, `idle` and `waiting` from Claude Code's session record. Until the record exists (a role on the folder-trust question), the quiet time comes from the tmux window, and in the `panes` layout all roles share it. `team status --json` also sets `waiting_human` when the last 15 lines of a pane show a permission prompt ("Do you want to …", "Would you like to proceed", `❯ 1. Yes`) or an agent's question form ("Enter to select … Esc to cancel", "Review your answers"). A bare "Esc to cancel" does not count, because owner menus such as `/rewind` show it too. The patterns are checked on live `claude` 2.1.295 for a permission prompt, a question form and `/rewind`; the "Review your answers" screen is not checked. A report or a question in plain text, without the question tool, looks like idleness to `team`; that is why `team reap` keeps an agent that still has a task.
- A role with a worktree does not start in a repository without commits: its branch would share no history with the main branch. `team spawn` exits with code 1 and creates nothing, `team up` refuses before the first pane if such a role has `start: always`, and `team check` warns once per repository. Make a first commit, then start the role.
- Claude Code MCP servers in local scope and skills from `.claude/` are tied to the directory they were set up in. Roles in worktrees do not see them. Give a role the MCP servers it needs with the `mcp` field and the `mcp_servers` block; skills from the root's `.claude/` cannot be connected this way.
- The manager in tmux starts with a clean context: your current conversation does not carry over. It learns the state from the tracker, the branches and your first message.
- Every role is a separate Claude Code session and spends your subscription limits or API tokens on its own.
- `team send --paste` types into the input line. If you are typing in the same pane at that moment, the texts mix.
- `team` does not store or assign tasks, does not merge branches, does not watch for stalled tasks (a watcher role can, if your project adds one), and does not use the network.
