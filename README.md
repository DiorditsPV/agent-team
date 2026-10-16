# agent-team

A team of Claude Code agents in tmux: you talk to one manager; roles are permanent, sessions are disposable — state lives in git and your tracker, not in the agent's context.

`team` is a command-line tool that starts Claude Code sessions from role files kept in your project's `agents/` directory. The tool knows nothing about your project: roles, zones, rules and the test command all live in those files.

## How it works

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/agent-team-dark.svg"><img src="docs/images/agent-team-light.svg" alt="You talk to the manager, which sends tasks to the developer, reviewer and writer roles and gets reports back; the roles commit to git, the manager verifies and merges, and keeps task status in the tracker." width="880"></picture>

The team lives in one tmux session, `team-<project>`: the manager on the left, every other role in a pane on the right, so you can attach and watch them all. A role that edits files works in its own git worktree on its own branch. Every role gets a fixed list of allowed tools: file reading and editing, `git`, the project's test command, and whatever its role file adds.

The numbers on the diagram follow one task:

1. **Task.** The manager sends the task with Claude Code's built-in `SendMessage` to the role's session socket.
2. **Commit and report.** The role commits to its branch and reports back over `SendMessage`.
3. **Verify.** The manager accepts work by the commit and the test output, not by the report. A reviewer role can sit in between.
4. **Merge.** The manager fast-forwards `main` to the role's branch or returns the task. A role never merges its own work, and the tool never merges anything: the merge rule is in the manager's role file, and the library manager merges only what you named.

The manager keeps each task's status in the tracker; a role with access to the tracker updates it too.

The stacked cards behind each role are its sessions. A role keeps its file, name, zone and worktree; the session behind it is replaceable. When a session's context fills up or it crashes, the manager asks for a handoff (`team handoff <role>`): the role writes what is done, in progress and next to the task in the tracker. Then `team restart <role> --fresh` starts a new session from the handoff, the branch and the tracker. Git and the tracker sit outside the TMUX · TEAM frame for this reason: the state lives there, not in an agent's context.

## Roles

A role is a Markdown file: copy the ones you need from [`roles/`](roles/) into your project's `agents/roles/` and fill in the zone, the test command and the tracker.

| Role                              | What it does                                                     | Kind     |
|-----------------------------------|------------------------------------------------------------------|----------|
| [`manager`](roles/manager.md)     | Runs the queue, assigns tasks, accepts work, merges on your word | manager  |
| [`developer`](roles/developer.md) | Changes code and tests in its own zone                           | executor |
| [`writer`](roles/writer.md)       | Writes documentation from the code and developer reports         | executor |
| [`reviewer`](roles/reviewer.md)   | Reviews a branch before merge: accept or return                  | reviewer |
| [`judge`](roles/judge.md)         | Independently checks high-stakes work for failure scenarios      | reviewer |
| [`data`](roles/data.md)           | Schema, migrations and pipelines; every bulk change reversible   | executor |
| [`optimizer`](roles/optimizer.md) | Improves a measurable metric with before-and-after measurements  | executor |
| [`assistant`](roles/assistant.md) | Gathers facts and prepares decisions for the manager; read-only  | executor |
| [`watcher`](roles/watcher.md)     | Spots stalled tasks, idle roles and unmerged branches (untested) | watcher  |

Shared rules — reporting, safety, git worktrees, the tracker cycle, data reversibility — are in [`roles/shared/`](roles/shared/); a role pulls them in through its `includes` field. How to adopt a role step by step: [`roles/README.md`](roles/README.md) (in Russian).

## Principles

- **One conversation.** You talk only to the manager; it assigns tasks and accepts work.
- **Identity apart from session.** A role is a file, a name, a zone and a worktree; its session is replaceable.
- **State outside the agent.** Tasks live in the tracker and results in git, so any session can be recreated.
- **Checking and merging are separate.** The one who does the work does not accept or merge it.
- **Restricted permissions.** Each role gets an explicit tool list; the tool never switches permission checks off, and roles inherit your default permission mode.
- **No project knowledge in the tool.** Zones, safety rules, the tracker and the test command live in `agents/`.

The approach comes from Steve Yegge's Gas Town: identity separate from session, state outside the agent, a manager that assigns work, and checking kept apart from merging. Its stack (Beads, Dolt, the Deacon and Dogs hierarchy) is left out: here tmux holds the sessions, git worktrees hold the work, and the tracker you already use holds the tasks.

## Get started

You need tmux, git, [uv](https://docs.astral.sh/uv/) and Claude Code (`claude` signed in and on your `PATH`).

```bash
git clone https://github.com/DiorditsPV/agent-team && cd agent-team
uv tool install --editable .
cd <your project> && team init      # creates agents/; edit the roles, then run team check
team up && team attach              # starts the manager and opens tmux
```

**Full guide for you or your agent:** [`docs/agent-guide.md`](docs/agent-guide.md). It covers requirements, the `/a-team` skill, editing `agents/`, the folder-trust prompt, the first message to the manager, every command, session replacement, stopping, and known limitations. You can hand it to Claude Code as is.

## Documentation

- [`docs/agent-guide.md`](docs/agent-guide.md) — setup and operation, step by step.
- [`roles/`](roles/README.md) — role library: nine roles, shared rules for them, and how to adopt them in a project.
- [`docs/SPEC.md`](docs/SPEC.md) — design and decisions: file formats, launch, permissions, messaging.
- [`CLAUDE.md`](CLAUDE.md) — brief for agents that develop the tool itself.

The guide and this page are in English; the specification, the role library and the `/a-team` skill are in Russian.

## License

MIT — see [`LICENSE`](LICENSE).
