# agent-team: setup and operation guide

This guide takes you from a clean machine to a running team and back: install `team`, describe the team in your project's `agents/` directory, start it in tmux, give the manager its first task, replace a role's session, and stop the team. It is written so that you can follow it yourself or hand it to Claude Code as a task.

What this guide does not cover:

- The full role-file format and design decisions. They are in [`SPEC.md`](SPEC.md) (in Russian); the fields you need to edit are listed in step 5.
- Which roles to pick. Ready roles and advice on when to use each are in the [role library](../examples/README.md) (in Russian).

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
создан agents/shared/reporting.md
создан agents/team.yaml
создан agents/templates/handoff.md
создан agents/templates/task-assignment.md
Дальше: отредактируйте agents/roles/*.md под проект, затем team check и team up.
```

The lines say: "created …" for each file, then "Next: edit agents/roles/*.md for the project, then team check and team up."

If `agents/team.yaml` already exists, `team init` stops with an error and overwrites nothing.

## 5. Edit `agents/` for your project

The directory holds four kinds of files:

- `agents/team.yaml` — who is on the team and how it starts;
- `agents/roles/<role>.md` — one file per role: settings in the frontmatter, the agent's instruction in the body;
- `agents/shared/*.md` — rules shared by several roles;
- `agents/templates/*.md` — message templates for assigning a task and for a handoff.

Edit `agents/team.yaml`:

| Field           | What to set                                                                                                                                                    |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `project`       | Project name; the tmux session is called `team-<project>`.                                                                                                     |
| `repo`          | Optional. The main repository; the manager runs there and `.team/` is kept there. Defaults to the directory that holds `agents/`.                              |
| `layout`        | `panes` — all roles in one window, manager on the left; `windows` — a window per role. `team init` writes `panes`; if the field is missing, `windows` applies. |
| `worktree_root` | Where role worktrees are created; a relative path counts from `repo`.                                                                                          |
| `test_command`  | The project's test command, for example `uv run pytest`. Its first word is added to every role's allowed tools.                                                |
| `manager`       | The name of the manager role.                                                                                                                                  |
| `roles`         | The list of roles, each with a `start` value (below).                                                                                                          |

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
| `zone`        | Files and directories only this role edits. `team check` warns when two roles list the same entry. The agent does not see this field, so repeat the zone in the body.                                          |
| `includes`    | File names from `agents/shared/`, for example `[reporting.md]`, appended to the role's instruction. |
| `allow`       | Tools beyond the default set, in Claude Code `--allowedTools` syntax, for example `Bash(ruff *)` for a linter or a tracker's MCP tools. |
| `add_dirs`    | Extra directories the role may access.                                                                                                                                                                         |

Every role may use `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Bash(git *)` and `Bash(<first word of test_command> *)` without asking; the manager also gets `Bash(team *)`. Add anything else through `allow`.

Then:

1. Set `status: active` on the scaffold `executor` role, or replace it with roles from the [role library](../examples/README.md). Copy a library role together with the files listed in its `includes` and fill in its `<…>` placeholders.
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
manager: запущена, панель %0 в tmux-сессии team-<project> (<directory>)
Подключиться: team attach   (tmux-сессия team-<project>)
```

That is: "manager: started, pane %0 in tmux session team-<project>", then "Attach: team attach". The pane number varies. `team up` starts the manager and every role with `start: always`; with the scaffold, that is the manager alone.

Then run `team attach` if you are a human; an agent skips it and uses `team peek manager 30`. `team attach` opens the tmux session on the manager's pane; `team attach <role>` opens it on that role's pane.

tmux keys (prefix `Ctrl-b`):

- `Ctrl-b` then an arrow key — move to the neighbouring pane;
- `Ctrl-b z` — zoom the current pane in or out;
- `Ctrl-b d` — detach from tmux; the agents keep working.

Do not close a pane with `exit`: that stops its agent.

## 8. Answer the folder-trust prompt

In a directory where `claude` has never run, it asks whether you trust the folder. The question appears once for the manager and once for each role with a new worktree, and the role waits in its pane until a human answers.

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

To look without interfering, run `team status` (roles, state, how long each has been quiet, `SendMessage` address) or `team peek <role>` (the last 40 lines of the role's pane).

## Commands

Run `team` with no arguments to print a short version of this workflow.

| Command                           | What it does                                                                                                                             |
|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `team`                            | Prints the workflow.                                                                                                                     |
| `team init`                       | Creates `agents/` in the current directory; never overwrites an existing `team.yaml`.                                                    |
| `team check`                      | Checks the team description without starting agents: tmux and `claude`, roles, included files, manager `kind`, worktrees, zone overlaps. |
| `team up [--resume]`              | Starts the manager and roles with `start: always`; `--resume` continues their previous sessions.                                         |
| `team spawn <role> [--resume]`    | Starts one role.                                                                                                                         |
| `team status`                     | Lists roles, their state, how long each has been quiet, and their `SendMessage` address.                                                 |
| `team addr <role>`                | Prints the role's address (`uds:…`) for `SendMessage`.                                                                                   |
| `team peek <role> [lines]`        | Prints the last lines of the role's pane; 40 by default.                                                                                 |
| `team attach [role]`              | Attaches to tmux; to the manager's pane by default.                                                                                      |
| `team handoff <role> [--paste]`   | Prints the address and the handoff request to send; with `--paste`, types the request into the role's input line.                        |
| `team restart <role> [--fresh]`   | Recreates the role's session: resumes the previous one, or with `--fresh` starts a new one.                                              |
| `team send <role> --paste <text>` | Fallback: types text into the role's input line; the role takes it as the user's words.                                                  |
| `team down [role]`                | Stops one role, or the whole team.                                                                                                       |

Without `--paste`, `team send` delivers nothing: it fails and prints the role's address for `SendMessage`.

## Replace a role's session

Replace a session when its context is full, it has crashed, or the role must restart with a changed instruction. The manager usually does this; you can ask it to.

1. Run `team handoff <role>`. Expect it to print the role's address and a request text. From a Claude Code session, send that text with `SendMessage` to the address; from a plain shell, run `team handoff <role> --paste` instead, which types the request into the role's input line. The request asks the role to fill in `agents/templates/handoff.md`, print it in its pane, post it to the tracker task, and then do nothing more; the role stays open.
2. Run `team peek <role> 60`. Continue when the filled-in template, starting with `Роль:` (Role), is visible.
3. Run `team restart <role>` to continue the same session, or `team restart <role> --fresh` to start a new one that picks up from the handoff, the branch and the tracker.

If the whole team was stopped with `team down`, run `team up --resume` to bring it back with the previous sessions.

## Stop

1. For each role with unfinished work — uncommitted changes, a task in progress — request a handoff first (previous section).
2. Run `team down <role>` to stop one role, or `team down` to stop the whole team.
3. Run `team status`. Expect `не запущена` (not running) for every stopped role.

## Known limitations

- A new directory triggers the folder-trust prompt, and the role waits until a human answers in its pane (`team attach <role>`).
- `team` does not set a permission mode: roles inherit your Claude Code default (`permissions.defaultMode`). If that mode asks before running a tool outside the role's list, the role waits for a human in its pane.
- The "quiet" time in `team status` is measured per tmux window, so in the `panes` layout all roles share it. `team` cannot yet tell a busy role from a waiting one.
- Claude Code MCP servers in local scope and skills from `.claude/` are tied to the directory they were set up in. Roles in worktrees do not see them: connect what a role needs separately; tracker work usually stays with the manager.
- The manager in tmux starts with a clean context: your current conversation does not carry over. It learns the state from the tracker, the branches and your first message.
- Every role is a separate Claude Code session and spends your subscription limits or API tokens on its own.
- `team send --paste` types into the input line. If you are typing in the same pane at that moment, the texts mix.
- `team` does not store or assign tasks, does not merge branches, does not watch for stalled tasks (a watcher role can, if your project adds one), and does not use the network.
