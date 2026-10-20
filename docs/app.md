# AgentTeam: the desktop app

This document explains how the macOS app in [`app/`](../app/) works and why it is built this way. It covers:

- what each screen shows and does;
- how your message reaches the manager;
- how the app watches tmux and when it calls `team`;
- what the app costs the machine while it runs.

It is for contributors who change the app and for users who want to know what the app does to their team and their CPU.

What this document does not cover:

- How to build and install the app. That is in the [README](../README.md#desktop-app).
- The `team` commands and their JSON output. Commands are in the [guide](agent-guide.md#commands); the field contract of every `--json` command is in [`SPEC.md`](SPEC.md) (in Russian), section «Машиночитаемый вывод».

You need to know the team's vocabulary from the [guide](agent-guide.md): manager, role, agent (`role#n`), handoff, event log. You also need a working knowledge of tmux sessions and panes. tmux control mode is introduced below where it is first used.

The app's interface is in Russian. Labels below are given in English with the Russian label in parentheses.

## What the app is

AgentTeam is a native window over the `team` CLI and tmux. It shows what every agent is doing, lets you chat with the manager, and edits roles. It adds no logic of its own to the team:

- It reads state from `team … --json`, from tmux, and from files that `team` and Claude Code write.
- It changes state through `team` commands, by typing your message into the manager's pane, and by sending the manager's pane an Esc key when you interrupt its turn. With the [Claude Code line](#the-claude-code-line) on, it sends your keys to the manager's pane. It never types into an agent's pane.

The app is built around three decisions. Each has its own section below.

- **One tmux connection.** The app holds one tmux control-mode client for all projects and sends every tmux command over it.
- **Output is a signal.** A pane's output stream tells the app that the pane changed. What the app reads is a fresh capture of the pane, taken at a capped rate.
- **Events, not timers.** The app re-reads state when tmux, the file system or you report a change. The repeating timers are two one-minute checks of tmux, a one-minute call of `team reap` and a one-minute refresh of the usage limits, described in [Load](#load).

## The Team screen

The window has a sidebar on the left, the chat with the manager in the middle, and a column of agents on the right.

### Sidebar

The sidebar lists projects and the sections of the selected project.

- **Projects.** Every tmux session named `team-*` is a project. Connect project (Подключить проект) adds a project directory that has `agents/team.yaml`; it stays in the list while its team is stopped, and a stopped project has a button to start it. The context menu of a project starts the team, removes the project from the list, or hides it.
- **Sections.** Team (Команда), Roles (Роли), Handoffs (Передачи, with the count of waiting handoffs), Journal (Журнал) and, at the bottom, Settings (Настройки). The team settings and the `team check` result sit on the Roles screen, described in [Roles](#roles).
- **Usage limits.** Under Settings, two lines show your Claude subscription limits: `5 ч: 62 % · сброс 18:40` for the 5-hour window and `неделя: 41 %` for the week. A line turns amber from 80 %. When the reset time has passed, the line reads `окно сброшено`. The tooltip gives the source and its age. Without data the sidebar shows `лимиты: нет данных`; for an API key, Bedrock or Vertex, which have no subscription limits, the lines are hidden. See [Usage limits](#usage-limits).
- **Footer.** The tmux session and the project's tracker.

⌘\ hides and shows the sidebar. The app remembers the choice.

### Header

The header holds the project name, a Team / Manager (Команда / Менеджер) switch, New agent (Новый агент), and a menu with Refresh (Обновить) and Stop team (Остановить команду…).

- **Manager mode** gives the chat the full width; Show agents (Показать агентов) brings the column back.
- **New agent** asks for a role and runs `team spawn <role>`.
- **Stop team** asks for confirmation, then runs `team down`.

### Agent column

The agent column is 420 points wide by default and at least 320; the chat keeps at least 420. Drag the border to resize the column, and double-click it to return to 420. The width is one setting for all projects.

A strip above the column shows the number of agents and roles and three controls:

- a filter: all agents, working agents, or agents waiting for you (Все / Работают / Ждут);
- Collapse all / Expand all (Свернуть все / Развернуть все);
- the number of columns, 1 or 2. You switch it by hand; the app does not change it by window width. The choice is one setting for all projects.

Agents stand in the column by status, in four groups from top to bottom: working (a turn is running), waiting (a trust, permission or question prompt), idle or without data, and stopped (the pane has ended). Inside a group they are sorted by role, then by number `#n`. The order does not depend on whether a pane is collapsed or on the order in which `team` and tmux report the agents, so a poll that changes no status moves nothing. The status of a visible pane comes from its fresh capture, of a hidden one from the transcript; a background reader refreshes the groups once a minute, and a moved row slides over 0.25 seconds. A dot on the filter button shows that a filter is on. When a filter leaves nobody, the column says «Никто не ждёт ответа» or «Никто не работает» and offers Показать всех (Show all).

The panes share the column's height between their rows, at least 200 points each; below that the column scrolls. With two columns and an odd number of panes, the last pane takes the full row.

### Agent pane

An agent pane shows the agent's conversation, not its terminal. The body is a compact version of the Thread (Диалог) tab of the agent screen, described in [Agent screen](#agent-screen): it follows the end of the agent's Claude Code transcript and ends with the agent's turn row.

The pane's header is one line: the collapse button, the agent name (a square in the role's colour, the role and `#n`), the current task, the agent's model, how long it has run and its state. A waiting agent also shows Answer (Ответить), which opens the macOS Terminal app attached to the agent's pane. The mark «не роль» appears for a pane that is not the role's session. The Open agent screen icon is always visible and is the only way to open the agent screen from the column: a click on the header does nothing, and only the collapse button collapses.

The model is the short name, such as «Opus 5.5», «Sonnet 5.5» or «Haiku 4.5». The app takes it from the agent's transcript: the last assistant record that has a model, or the result of the last `/model` command, whichever is later. When the transcript has none, it falls back to the role's `model` field from `team status`; `inherit` and `default` give no name, and then nothing is shown. The same label appears in the collapsed row and in the breadcrumbs of the agent screen.

Under the header stand the agent's thread and, while subagents run, the [subagent strip](#subagent-strip). A pane whose process has ended shows «Панель завершилась. Перезапуск — на экране агента.» instead of both.

The collapse button turns a pane into a one-line row (44 points tall) with the task, the repository, the model, the time and the state; when the row is narrow, the time goes first and then the state shrinks to a coloured dot. A collapsed row stays at its place in the status order above, not above the expanded panes. The pane keeps its thread while collapsed, so expanding it shows the thread at once, without reading the transcript again. Which panes are collapsed is kept per project while the app runs and is not saved between launches.

### Subagent strip

While a session has subagents that are still running, a strip with a vertical line on its left shows them. It takes no room when the list is empty.

- The title is «N субагентов в работе» (with the right word ending); when the session's turn waits for background subagents, it adds «· ход ждёт их» and takes the accent colour.
- Each subagent has a row: a spinner, its type in bold (for example Explore), its task description on one line, and the running time («12 с», «3 мин 05 с»). A second line shows what it does now: its last tool call («Read · docs/SPEC.md») or the start of its last text.

The strip appears in the manager chat under the turn row (for the active project only), on the Thread tab of the agent screen, and, in a compact form, under the thread of an agent pane. The app reads the Claude Code files `<session>/subagents/agent-<id>.meta.json` and `.jsonl` and the session transcript, and polls only while a strip is on screen.

### Decisions waiting for you

A bar above the agents lists decisions that wait for you. It shows three kinds:

- **Folder trust.** The agent's pane shows Claude Code's folder-trust prompt. This happens in every new worktree.
- **Permission.** The agent's pane shows a permission prompt for a tool outside its allowed list, or another multiple-choice question. The app sees it in the pane tail, or `team status --json` reports `waiting_human`.
- **Your word.** The manager wrote a `waiting` event to the log (`team log waiting …`), for example before a merge, and no `owner` or `report` event for the same task followed it. A `waiting` event without a task is closed by an `owner` or `report` event of the same agent.

The manager itself counts too when its pane shows a prompt.

The bar has up to two buttons:

- **Answer manager (Ответить менеджеру)** appears when the manager waits on a prompt. It opens Terminal attached to the manager's pane.
- **Review (Разобрать)** appears when a decision comes from someone other than the manager. It switches to Manager mode, because the app expects you to settle decisions in the conversation with the manager. For an agent's trust or permission prompt the chat is the place to discuss it; the prompt itself is answered in the pane, as described next.

A trust or permission prompt of an agent can be answered only in the agent's pane, and the app does not press keys there. The manager's prompt can also be answered in [the Claude Code line](#the-claude-code-line). Open the agent, click Open pane (Открыть панель) to get Terminal attached to that pane, and answer the prompt with the keyboard.

## Chat with the manager

The chat is the manager's Claude Code transcript, not a copy kept by the app.

### Where the transcript comes from

The app needs the manager's session id and working directory:

1. Before `team status` answers, the app takes the session id from `.team/state.json`.
2. `team status --json` then confirms it and gives the working directory.

The transcript is `~/.claude/projects/<slug>/<session_id>.jsonl`, where `<slug>` is the working directory with every character other than an ASCII letter or digit replaced by `-`. If the file is not there, the app looks for `<session_id>.jsonl` in every directory under `~/.claude/projects`. If the file does not exist yet, the app waits for it with kqueue. Then it follows the file with kqueue: the last 3 MB on opening, then each new line. That tail feeds the manager status (context use, busy flag) and the queue of sent messages; the newest 600 records of it are the chat history the app keeps in memory for those. The chat feed itself is built from the whole session in 256 KB pages, the same way as an agent Dialog: it opens at the end and loads earlier pages as the owner scrolls toward the top, down to the start of the session. The feed is lazy (only visible rows are built), and its grouping is recomputed only when records, the visibility settings or the team change. While the owner reads away from the bottom, new events never move the visible text: only the "New ↓" button appears. When an earlier page is loaded at the top, a visible row is pinned: it returns to the place in the window where it stood when the page arrived, and every layout shift of that row (the lazy list refines the heights above the window as rows are built) is compensated at once, until the owner scrolls again.

kqueue and FSEvents, used here and below, are the macOS interfaces that report file-system changes to a process; with them the app waits for a change instead of polling.

### What the chat shows

The app shows these kinds of records:

- your message, with its pictures as thumbnails; a click opens a picture over the whole window and Esc closes it;
- a message the manager queued while busy (`queued_command`);
- a message from the manager to an agent (`SendMessage`), with the socket address replaced by the agent's name;
- an incoming message from another session;
- a tracker call: a tool of a connected MCP server (named `mcp__<server>__<action>`) whose action name contains `issue`, `comment`, `ticket`, `cycle` or `milestone`. The app does not know which tracker the project uses, so it goes by the action name;
- any other tool call, as its name and one line of its input;
- the manager's reply, rendered as Markdown;
- a divider «контекст сжат · HH:MM» ("context compacted") where Claude Code compacted the context; it replaces the compaction summary, which is not shown as a message;
- the end of a turn, with its duration and time.

Reminders and task notifications of the Claude Code harness appear as compact one-line entries. Other service text is hidden. Records of subagents are skipped.

Claude Code's built-in commands show only their output, as a card. The app builds a card from any output Claude Code writes as local command output, for example `/context`, `/agents`, `/model` or the result of a closed screen such as «Resume cancelled». The card has a title «<command> · HH:MM», a left rule and the output text without ANSI colours, in monospace and selectable. Without a known command name the title is «команда»; an empty output shows nothing. A skill or a plugin or user command shows one line «/name arguments · time». A command Claude Code does not know shows «Claude Code не знает команду /x. Возможно, имелась в виду /y». The Settings switches do not hide these cards. Several of the kinds above can be hidden in Settings, see [Display settings](#display-settings).

While you are at the bottom, the chat follows new records. When you scroll up, it stops following and shows New ↓ (Новые ↓).

### Header

The header shows the manager's state, model and how full its context is.

- **State.** Busy (в работе) from your message, or an incoming one, to the record that ends the turn; free (свободен) otherwise; not running (не запущен) without a manager pane.
- **Model.** The `model` field of the manager's last response, in the short form (see [Agent pane](#agent-pane)). The header line reads like «ведущая сессия · Opus 5.5 · контекст 18%». Unlike an agent's label, it ignores `/model`.
- **Context.** The sum of input tokens, cache-creation tokens and cache-read tokens in the last response's `usage`. The transcript does not record the size of the context window, so the app assumes 1,000,000 tokens, or 200,000 for models with `haiku` in the name. The percentage is an estimate on that assumption.

### Turn row and the reply being written

The transcript gets a reply block only when the block is complete; a long block appears on the manager's screen many seconds before it reaches the transcript. So while the manager's turn runs and the project is on screen, the app also watches the manager's pane. It gets the pane's output notifications and captures the screen at most 4 times a second. While the manager is idle, the app does not watch its pane.

From these captures the app shows two things at the bottom of the chat:

- **The turn row.** The spinner line of Claude Code above the input box: the verb, the elapsed time, the tokens, and the hint. The app looks for it in the last 8 lines of the screen; without such a line, the row is hidden.
- **The reply being written.** A draft «<manager> пишет…» ("writing…") with the text the manager is printing. The block from the transcript replaces the draft when it arrives.

The turn row has Stop (Стоп), see [Stopping a turn](#stopping-a-turn).

## Writing to the manager

You write only to the manager, in the input box under the chat. The box can be replaced by [Claude Code's own input line](#the-claude-code-line).

### The input box

- Enter sends; Shift-Enter or Option-Enter starts a new line. The box grows up to 8 lines.
- The text you have not sent is kept per project and survives a restart of the app.
- ⌘V with a picture on the clipboard, or a picture file dropped on the box, attaches the picture. The app saves it to `~/Library/Caches/<app id>/attachments/`: PNG, JPEG, GIF and WebP files as they are, anything else and clipboard images as PNG. A thumbnail with a remove button appears above the text. Attached pictures are not kept across restarts, and files older than a day are deleted when the app starts.

### Suggestions

The box suggests completions as Claude Code's own input does:

- **`/` at the start** lists slash commands: the built-in commands of Claude Code, the `.md` files in `~/.claude/commands`, and those in the project's `.claude/commands`. A project command overrides a user command of the same name, and a user command overrides a built-in one.
- **A word starting with `@`** lists files of the project directory, without hidden and service directories such as `.git`, `.team` and `node_modules`.
- **↑ in an empty box** goes back through your earlier messages: those in the manager's transcript and those sent in this run of the app. ↓ goes forward.

The list shows up to 8 items. ↑ and ↓ move the selection, Tab or Enter inserts it, Esc closes the list. Enter on a complete `/command` sends it.

### How the message reaches the manager

The app types your message into the manager's pane, the way you would at the keyboard:

1. It removes control characters except newline and tab.
2. It pastes each attached picture's file path into the pane separately, as a bracketed paste (`load-buffer`, then `paste-buffer -p`), 0.15 seconds apart. Claude Code turns a paste into an attachment «[Image #N]» only when the paste is nothing but a path, so each path goes alone.
3. It types the text with `send-keys -l`, in pieces of up to 1,500 characters. A newline is sent as Meta-Enter, which starts a new line in Claude Code without submitting. A tab becomes four spaces, because a typed tab would open Claude Code's suggestions. If the text ends with a word starting with `@` or `/`, a space is added so that Claude Code's suggestion list closes; otherwise Enter would pick an item from the list instead of sending.
4. After 0.12 seconds, `send-keys Enter` submits the message.

The app types rather than pastes because Claude Code wraps pasted multi-line text in `<pasted_content>`, and the manager then reads it as text from someone else, not as your words. Text that starts with `!` or `#` is the exception: typed as the first character, they switch Claude Code's input to shell command and memory mode, so such text goes as a bracketed paste.

The app finds the manager's pane in tmux's live pane list, not in the cached `status`. After sending, it records the message in the event log with `team log owner <manager> -- <text>`: the first 120 characters on one line, or «[картинка]» for a message with only a picture. The `--` keeps a message such as `--help` from being read as an option. If `team log` fails, the app skips the record silently.

### The queue

While the manager's turn runs, the app holds your message instead of typing it into the pane. Claude Code would queue a message typed during a turn, and you could no longer change or remove it there. The app decides that a turn runs from the manager's transcript, as in the chat header.

A held message appears in the chat at once, marked queued (в очереди), with three actions:

- **↑ now (↑ сейчас)** sends Esc to the manager's pane to interrupt the turn, waits half a second, and sends this message. The other held messages keep waiting for the end of the turn. The action is hidden while the manager's pane shows a permission or trust prompt, because Esc there would refuse the request.
- **✎ edit (✎ изменить)** removes the message from the queue and puts its text and pictures back into the input box, before what you have typed there.
- **× remove (× убрать)** deletes the message from the queue.

When the turn ends, the app sends the held messages one at a time, in order. It sends the next one only after the previous one appears in the transcript or is marked lost, so the chat shows them in the order you wrote them.

A message the app has typed into the pane is marked sent (отправлено) until the transcript records it; the app matches it by text, or by order and the number of pictures. If the manager has been idle for 2 minutes and the message is still not in the transcript, the mark becomes not delivered (не дошло), with Send again (Отправить ещё раз) and Remove (Убрать). While the manager's turn runs, the 2 minutes do not count, and held messages have no time limit. If typing into the pane fails, the text returns to the box with «Не отправлено: …» ("Not sent").

### Stopping a turn

Stop (Стоп) on the turn row, or Esc in an empty input box, sends one Esc key to the manager's pane, which interrupts its turn. The button appears only while the turn row is shown. While the manager's pane shows a permission or trust prompt, Stop is hidden and Esc is not sent, because Esc there would answer the prompt with a refusal.

Stopping also stops the queue: held messages are marked stopped (остановлено) and are not sent when the turn ends. Each of them keeps its three actions, so you decide what to send after the interruption.

## The Claude Code line

Instead of its own input box, the app can show the live bottom part of the manager's pane: Claude Code's own input line. Everything Claude Code offers there works as it does in a terminal: the `/` and `@` menus, history on ↑, `/rewind`, permission dialogs and multiple-choice questions. This is the one place where the app answers the manager's prompts itself.

The input box of the app has things Claude Code's line does not: a draft the app keeps, the queue of held messages, picture thumbnails and the suggestions of the app. [Writing to the manager](#writing-to-the-manager) describes them. The line has what the box does not: the menus that Claude Code draws itself.

### Turning it on and off

The mode is one setting for all projects, kept between launches. These places switch it:

- **Settings.** The switch «Поле ввода менеджеру» (Manager input) has two values: Поле приложения (the app's box) and Строка Claude Code (Claude Code's line).
- **The terminal icon** beside Send in the app's box. It shows only while the manager has a pane.
- **A command with its own menu.** When the text in the box starts with a command such as `/rewind`, `/resume`, `/model` or `/config`, a strip says that the command works in Claude Code's line. Its button moves the text to the line and does not press Enter; you press it yourself. The commands are in `ClaudeOwnMenus.commands`.
- **A waiting manager.** When the manager waits for an answer and the app's box is on, the strip above the box offers Включить строку Claude Code (Turn on Claude Code's line).

In the line, a pencil icon at the bottom right (Вернуться к полю приложения) switches back to the app's box.

### What it shows

The app takes the manager pane's screen and shows only its bottom part, below the chat. It draws that part with the terminal theme and font of [Themes](#themes) and [Display settings](#display-settings), and it puts the cursor where the pane has it. The part is one of these:

- **The input line.** The input between its two rules, with the status line under it. Above the line the part also holds:
  - the suggestion menu of `/` or `@`, when one is open;
  - the turn row of Claude Code, such as «✻ … (5s · esc to interrupt)», while the manager's turn runs.
- **A dialog.** A permission prompt, a multiple-choice question or a menu such as `/rewind`. The part starts at the rule above its title and runs to the bottom of the screen.

The part is at most 24 rows tall. The app finds its upper edge from the rules and hints Claude Code draws, not from a fixed number of rows; a form of unusual shape can be cut at the wrong place. If the screen has no input line, the area shows «Строка ввода Claude Code не найдена на экране панели» (Claude Code's input line is not found on the pane's screen). The pane's screen is read up to 60 times a second, as the table in [Output triggers a capture](#output-triggers-a-capture) shows.

When the dialog is a multiple-choice question of the manager's `AskUserQuestion` tool, the app replaces the pane's screen with the question card (AskQuestionCard). The card appears when all of these hold:

- the Claude Code line is on, or the Team screen is open;
- the pane has the question form open;
- the app knows the question, from the `question` field of `team status` or from an unanswered call in the transcript, and its options match the pane's screen by their labels.

If the form is open but the question is not recognised and Claude Code has cut the top of the form, the card does not appear. The area shows the pane's screen and the amber note «Верх формы не помещается в панель — вопрос появится целиком, как только будет записан».

The card has:

- the title «Вопрос менеджера»; with several questions, tabs by their headers («Вопрос N» without one), and a click moves to that question in the pane; with one question, «· <header>» after the title;
- the question text;
- the options `❯ N. <label>`, each with its description and a monospace preview when it has them; a multi-select question marks them «[✔]», «[ ]» or «[·]»;
- the row «N+1.» with the field «Свой ответ» and the button Ответить;
- the row «N+2.» «Обсудить в чате» («Chat about this»), which returns the question to the chat so that the manager asks it differently;
- a footer with the cursor position of the pane, the button Дальше (multi-select only, it sends Tab) and Отменить вопрос (Esc: the manager receives a refusal to answer).

You answer with a click on an option or with its digit; the arrow keys, Enter, Esc and Tab go to the pane. The app writes nothing to the manager directly: every answer is keys typed into the manager's tmux pane, the same keys you would press in a terminal.

The app does not resize the tmux window, because you may have it open in a real terminal. It lowers the font size, to at most the terminal size and at least 8 points, so that all columns of the pane fit the width of the area.

While the line is on, the app hides what the line already shows: the turn row and the reply being written under the chat, and the strip about a waiting manager. The chat feed above stays.

### Which keys go to the pane

The line takes keys when it has focus; it takes focus when it appears and when you click it. A key goes to the pane as tmux's `send-keys` sends it, so Claude Code sees what it would see from a terminal.

| You press                                    | The pane receives                         |
|----------------------------------------------|-------------------------------------------|
| Printable text                               | the text, typed through the macOS input system, so keyboard layouts, dead keys and input methods work; an input method's unconfirmed text is drawn at the cursor |
| Enter                                        | Enter                                     |
| Shift-Enter or Option-Enter                  | `\` and Enter, which starts a new line in Claude Code |
| Esc                                          | Esc                                       |
| Tab, Shift-Tab                               | Tab, Shift-Tab                            |
| Backspace, Option-Backspace, forward Delete  | Backspace, Option-Backspace (delete a word), Delete |
| ⌘-Backspace                                  | Ctrl-U, which erases the line             |
| Arrows, with Option, Ctrl or Shift           | the same arrows with that modifier        |
| Home, End, Page Up, Page Down                | the same keys                             |
| Ctrl with a letter A to Z                    | the same Ctrl combination                 |
| ⌘V with text on the clipboard                | the text, pasted as one block             |
| ⌘V with a picture on the clipboard           | Ctrl-V, and Claude Code reads the picture from the clipboard itself |

Other ⌘ combinations and Ctrl with a non-letter go nowhere.

Esc does not go while the pane shows a permission or trust prompt: there Esc is a refusal. The app beeps instead, and you answer the prompt with the other keys of the dialog.

### How it differs from the app's box

- **Messages are not held.** The line sends each key at once. A message typed while the manager works is queued by Claude Code, and the app cannot change or remove it. The ↑ now, ✎ and × actions and the Stop button are gone; Esc in the line interrupts the turn.
- **The app keeps no draft.** The text lives in the pane. Switching back to the app's box does not carry it over.
- **Pictures are not thumbnails.** ⌘V sends Ctrl-V to Claude Code, which shows its own «[Image #N]». The area is not a drop target: a picture file dropped on it is not attached, as it is in the app's box.
- **Nothing is logged.** The app writes `team log owner` only for messages from its own box. A message typed in the line does not reach the event log.
- **The pane is watched while the line is visible.** The app reads the manager's pane at the rate above even when the manager is idle, because you may type or open a menu at any moment.

## Agent screen

The agent screen opens from a pane. Its tabs:

- **Thread (Диалог)**, the default. The agent's Claude Code transcript as a conversation: input typed into the pane, messages to and from the agent, tool and tracker calls, replies as Markdown, turn ends and compaction dividers. The app reads the transcript in pages of 256 KB from the end and loads earlier pages as you scroll up. The turn row of the agent's pane sits at the bottom, without Stop.
- **Output (Вывод).** The live screen of the agent's pane with 300 lines of history.
- **Handoffs (Передачи)**, with their count.
- **Instruction (Инструкция).** The built instruction of the role.
- **Permissions (Права).** The allowed tools.

An inspector on the right shows the session, the worktree with its uncommitted changes, and the zone and permissions. Open pane (Открыть панель) opens Terminal with `tmux attach` to that pane.

The actions menu has four items, and each asks for confirmation first:

- **Hand off (Передать)** sends the manager the message «Подготовь передачу агента <agent>: team handoff <agent>, затем restart --fresh, когда файл заполнен.» ("Prepare a handoff for agent <agent>: team handoff <agent>, then restart --fresh once the file is filled in."). The message appears in the chat and is logged with `team log owner` like any message of yours.
- **Continue session (Продолжить сессию)** runs `team restart <agent>`.
- **New session (Новая сессия)** runs `team restart <agent> --fresh`.
- **Stop agent (Остановить агента)** runs `team down <agent>`.

## Role check

An agent's conversation can leave the process that `team` started and move to a background task of Claude Code, which has no role prompt. `team status --json` reports this in `role_check` (see the specification, «Проверка роли»). When `role_check.ok` is `false`, the app shows it in three places:

- **Banner.** On the agent screen and in the chat: «В панели <агент> не сессия роли: <причина>». The reason is one of: the conversation went to a background task, another process not started by `team` holds it, or the pane's process runs without the role file. The banner has the button Restore role (Восстановить роль), which runs `team restart <agent>` without `--fresh`: the pane comes back with the role prompt and the same session.
- **Red mark.** A collapsed agent row shows a warning triangle, and the pane header a badge with a short reason: `в фоне`, `чужой процесс`, `без роли`.
- **Writing to the manager.** If the manager's pane is not a role session, the app does not write to it: the message, Esc and the queue on exit wait, and the banner says so. Before each write the app also confirms the manager's role with a fresh `team status --json`, about 0.2 seconds per message, so a message never reaches a conversation without the role. The same hold applies until the first `team status` has answered.

`role_check.ok` of `null` (no data yet) raises no alarm.

## Usage limits

`team` wraps the status line of every role it starts: the wrapper saves the latest status-line JSON with `rate_limits` to `.team/statusline.json`, and then runs your own status-line command, so the line looks the same. The app reads that file for each project and shows the freshest one; its fallback is the `/usage` cache in `~/.claude.json`. The sidebar refreshes the limits once a minute. A role started before this feature has no wrapper: its limits appear after `team restart`.

## Task titles

Wherever the app names an agent's task, it shows the task title that the manager set with `team task`, not the tracker number:

- the agent pane and its collapsed row;
- the agent screen;
- the agents of a role on the Roles screen;
- the journal.

The tooltip shows the full title, the task number and when the title was set. The title comes from the `task_title` field of `team status --json`. With a `team` that has no such field, the app shows the task number: from `status`, or from the latest event with a task in the log.

## Roles

The Roles screen has a strip of team settings and the `team check` result at the top. Below it, the roles are listed in two blocks on the left; the selected role opens on the right.

The strip is read-only and shows:

- `layout`, `manager` and `tracker` (`не задан` when empty), and `worktree_root` (`рядом с проектом` when empty) from `agents/team.yaml`;
- the auto-stop setting (автоостановка): `N мин` or `выкл`, from `idle_stop_minutes`; without the key the cell shows 15 with the caption «по умолчанию». Its tooltip says that `on_demand` agents without a task and input are stopped after this many idle minutes, and that the app calls `team reap` once a minute. You type the number of minutes, `выкл`, `off` or `false` (the last three write `off`); an empty field writes 15; Enter or the Записать button (it appears once the text differs from the saved value) runs `team set idle_stop_minutes <N|off> --json`, and after success the app rereads `team.yaml`. The field is disabled while the call runs. A value that is not a whole number above zero gets a red frame and the hint «минуты или «выкл»» under the field, and nothing goes to `team`. An error from `team set` shows under the field and disappears when you edit the text;
- the `team check` button (`Проверяю…` while it runs), then the result: `N ✓` with `без замечаний`, or `N !` with a chevron that opens the report. Under the report a line `team check · <age>` shows how long ago it ran. The same button runs the check again.

The blocks:

- **Project roles (Роли проекта).** In the order of `team.yaml`. A role that inherits a shared role (or has the name of one) is marked «← общая <имя>»; the tooltip says «на основе общей роли <имя>».
- **Shared roles (Общие роли).** The roles of the library that ships with `team`, read-only. A shared role that the project already has, by name or through `extends`, is not listed again: it is the project role marked «← общая <имя>». A shared role not yet in the project has Add (Добавить) in the list and Add to project (Добавить в проект) in its card; both do the same.

Each project role in the list has a start-mode switch: Always (постоянная), On demand (по требованию), and Manual (вручную), shown only for a role already in that mode. A click runs `team role set <role> --start <always|on_demand|manual>` and saves only the mode. If the mode was changed in the role's card and not saved, the switch has an amber outline. An always-on role starts with the team (`team up`); an on-demand role starts when the manager gives it a task. The manager and the shared roles have no switch.

The list comes from `team roles --json --library`. With a `team` that does not know `--library`, the app repeats the call without it and shows project roles only.

For a project role you can edit:

- the title;
- the model: opus, sonnet or haiku;
- the description;
- when it starts: manual, always or on demand (Вручную / Всегда / По задаче).

Save (Сохранить, ⌘S) runs `team role set <role>` with only the changed fields. If agents of the role are running, Save and restart (Сохранить и перезапустить) also runs `team restart <agent>` for each of them, continuing their sessions. An inheriting role shows the text of its shared role in a collapsed, read-only block.

- **New role (Новая роль)** asks for the file name, title, model, description and start mode, and runs `team role new <name> --title … --model … --start …`.
- **Add (Добавить)** on a shared role runs `team role new <name> --extends <name>`. If `team` refuses, the app shows its error.
- **Technical settings (Технические настройки)** show the worktree, zone, includes and tools read-only, with the role file as its body, as the built instruction, or as the whole file. An inheriting role opens on the built instruction. The manager edits these settings together with the role file.

## Other screens

- **Handoffs (Передачи).** Every handoff file, with its state and the agent it belongs to, and a button that opens the agent.
- **Journal (Журнал).** The event log, newest first. It has a period menu (today, 7 days, 30 days, all time), a type filter with several choices, an agent menu, and a search by task, commit and text.
- **Settings (Настройки).** Themes and display settings, described below, and the `team` tool: its path, the call the app makes, the `team` version, the tmux server, and an Environment (Окружение…) window. The Environment window checks tmux, `team` and their versions. ⌘, opens a short form with the path to `team`, the tmux server and the same Environment button.

## Themes

The app has three independent themes:

- **Window.** App appearance (Оформление приложения), which is the app's own dark design, or any terminal palette. The palettes come in two groups, dark and light. When the window theme has a light background, menus and scroll bars switch to the light system appearance.
- **Chat.** Like the window (Как окно), the default; App appearance; or any palette. It colours the chat's background, input box, text, cards, team messages, Markdown and accent.
- **Terminal.** Any palette. It colours everything that shows an agent: the agent panes, the Thread tab and the Output tab.

The Settings screen starts with a mock window (a fixed preview, not clickable) with the project sidebar, the header, the manager chat, the agent column and a pane. Each zone reads its own theme, so a palette you pick changes its zone at once. Below it stand three columns, Окно, Чат менеджера and Агенты и терминал, with the palettes as tiles (the theme's name on its background and a strip of six colours). Each column has its own Сбросить button that resets only that colour. The window layout itself has no setting: the mock window only previews colours.

The dark palettes are Default (По умолчанию), Dracula, One Dark, Dark+, One Dark Pro, Monokai, GitHub Dark, Darcula, Nord, Gruvbox Dark, Tokyo Night, Catppuccin Mocha and Solarized Dark. The light palettes are Light+, GitHub Light, Gruvbox Light, Catppuccin Latte and Solarized Light.

The app keeps text readable on any combination by adjusting colours to a contrast ratio, computed as in WCAG:

- In the chat, the main and muted text, the accent and the role colours are brought to at least 4.5:1 against the background and the card surfaces. The app changes only a colour's lightness, never its hue.
- In a window theme built from a palette, status and role colours are at least 3:1, and muted text is at least 4.5:1 on surfaces.
- Role colours cannot be set: the manager takes the theme's accent, and the other roles take the five colours of the theme's palette (cyan, violet, periwinkle, rose, amber) in the order of the project's roles, and cycle when roles outnumber colours; a role the project does not list gets a colour from a hash of its name. The five colours are spread by hue until each pair differs by at least 15 in CIEDE2000. In the agent area the colours come from the terminal theme, elsewhere from the window theme. The Roles screen shows the colour as a square but does not edit it.
- In the terminal, the palette's own ANSI colours are used as they are. RGB colours that Claude Code prints are brought to at least 4.5:1 against the palette's background.

## Display settings

The chat and the terminal each have a font, a size and a spacing. Each block has a Reset (Сбросить) button.

- **Chat.** Size 11–22 points, 14 by default. Spacing adds 0–12 points between lines, 5 by default. Spacing also scales the gaps between records and inside them, from a quarter of the default gaps at 0 to about twice the default at 12. The chat settings apply to every conversation view: the chat, the Thread tab and the agent panes.
- **Terminal.** Size 9–20 points, 12 by default. Spacing is the line height, 1.00–1.60 of the font size, 1.15 by default. It applies to the Output tab.

What to show in feed (Что показывать в ленте) hides kinds of records, separately for the manager chat and for the agents (the Thread tab and the agent panes). Everything is shown by default. The switches:

- Bash commands;
- reading and editing files (Read, Edit, Write, NotebookEdit);
- other tools;
- team messages;
- tracker calls;
- «контекст сжат» dividers;
- turn duration and time;
- the turn row;
- the reply being written, for the manager chat only.

A switch applies at once to every open feed, and a hidden kind leaves no empty gap: a block of actions whose every line is hidden disappears as a whole. The filter works when the feed is shown, not when the transcript is read, so turning a switch back on shows the records again without reloading.

## Finding tmux and `team`

An app started from Finder gets a short `PATH` from launchd, and tmux from Homebrew is not on it. So at start the app reads your login shell's environment: it runs `$SHELL -i -l -c 'env -0'`, or `$SHELL -l -c 'env -0'` if that fails, with a 3-second limit. It takes `PATH`, `LANG` and the `LC_*` variables from it and adds `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, `/usr/bin` and `/bin` to `PATH`. If the locale is not UTF-8, it sets `LANG=en_US.UTF-8`. Then it looks for tmux and `team` again.

The app passes this environment to every process it starts, without `TMUX`, `TMUX_PANE`, `CLAUDECODE` and the `CLAUDE_CODE_*` variables of a parent Claude session. It runs every tmux command with `-u`, so that tmux treats the output as UTF-8.

The `toolPath` setting tells the app where `team` is. The app resolves it in this order:

1. If `toolPath` is an executable file, the app runs it.
2. If `toolPath` is a directory with `.venv/bin/team`, the app runs that file. This is the fastest way.
3. If `toolPath` is a directory without `.venv` and `uv` is found, the app runs `uv run --project <toolPath> team`.
4. Otherwise the app runs `team` from `PATH`.

By default `toolPath` is the repository of the `team` found on `PATH`, if that `team` is a repository's `.venv/bin/team`.

Settings show the `team` version from `team --version`: the version for «team 0.1.0», and unknown (неизвестна) for «team unknown» or an error. The version is for you only. Whether `team` is usable the app decides by whether `team status --help` mentions `--json`.

The app uses the default tmux server. To use another one, start the app with `--socket <name>`, set `TEAM_TMUX_SOCKET`, or set the `tmuxSocket` key in the app's defaults. The app then runs every tmux command with `-L <name>` and passes `TEAM_TMUX_SOCKET=<name>` to `team`, so both look at the same server.

### The tracker label

The sidebar shows the tracker from the `tracker` field of `team status --json`: the string itself, or the `kind` field when `team.yaml` gives the tracker as a mapping. An empty value shows «трекер не задан» ("no tracker"). Composition reads the `tracker:` line of `agents/team.yaml` itself and shows its value as written. For a mapping written on the following lines the line has no value, and Composition shows the label from `status` instead.

## One tmux connection

tmux control mode (`tmux -C`) is a client that reads tmux commands from stdin and writes their replies and server notifications to stdout as text lines. The app starts exactly one such client:

```
tmux -u -N -C attach-session -f ignore-size -t =team-<project>
```

- `-f ignore-size`: the size of the app's window does not resize the panes.
- `-N`: if the tmux server has just exited, the client does not start a new one.
- The client is not read-only, because a read-only client cannot run `send-keys`.

Commands go to the client's stdin, and tmux answers them strictly in the order received. The app matches replies to commands by that order. Listing sessions and panes, capturing a pane, typing your message and sending Esc all go over this channel. One process starts with each connection: a `tmux -N list-sessions` that finds the session to attach to.

When you select another project, the app runs `switch-client` on the same connection. When a project's session closes, tmux moves the client to some other session. The app leaves that session at once: it switches to another `team-*` session if one exists, or closes the connection.

### When there are no `team-*` sessions

Without `team-*` sessions the app holds no connection. It could attach to one of your own sessions to receive notifications, but it does not. A tmux command without `-t` targets the most recent session, and attaching makes that session the most recent one. Your own `tmux attach` and every tmux command you run without `-t` would then land in the session the app chose. That session would also look attached when nobody uses it.

How the app notices a new team depends on whether a tmux server runs:

- **The server runs.** The app runs `tmux -N list-sessions` once every 60 seconds, and right away when you select a project or start a team. This check runs only in this state.
- **No server.** The app starts no process at all. It watches the socket directory with kqueue: `$TMUX_TMPDIR/tmux-<uid>`, or `/tmp/tmux-<uid>` when `TMUX_TMPDIR` is not set. After a reboot that directory does not exist yet. The app then watches the nearest existing parent and moves into the directory when it appears. The app waits for the socket file of its server: `default`, or the name given with `--socket`. When the file appears, the app lists the sessions. It connects if a `team-*` session exists, and otherwise moves to the one-minute check above.

## Live output

### Visible panes stream, hidden panes pause

tmux lets each control-mode client set, per pane, whether it receives that pane's output (`refresh-client -A <pane>:on|off|pause|continue`). The app uses this to receive output only for panes it needs:

- A visible agent pane, the agent screen's pane, the manager's pane during its turn, and the manager's pane under the Claude Code line get `on` and `continue`.
- Every other pane of the project gets `pause`.
- When the app's window is hidden, minimized or fully covered, every pane gets `pause`.

The app never uses `off`. When the app is the only client of a session, `off` makes tmux stop reading the pane. The agent in that pane then blocks on its next write to the terminal and stops working. `pause` only stops the notifications; tmux keeps reading the pane. An integration test checks this on a pair of panes that each print 20 MB: the paused pane finishes, the pane with `off` does not finish until it is switched back `on` (`testPauseDoesNotBlockPaneButOffDoes` in `app/Tests/AgentTeamCoreTests/TmuxIntegrationTests.swift`).

The app also sets `pause-after=5`: if the app falls 5 seconds behind a pane's output, tmux pauses that pane. For a visible pane the app answers with `continue`.

### Output triggers a capture

The app does not draw the output stream. An output notification only marks the pane as changed. The app then reads the pane's current screen with `capture-pane -p -e -J` over the same channel, at a capped rate:

| Where                                               | Capture                                     | At most       |
|-----------------------------------------------------|---------------------------------------------|---------------|
| Agent panes, and the manager's pane during its turn | the visible screen                          | 4 per second  |
| Agent screen                                        | the visible screen and 300 lines of history | 15 per second |
| The Claude Code line (manager pane)                 | the visible screen and the cursor           | 60 per second |

An agent pane shows the transcript, so its capture serves the turn row and the prompt check. So the drawing cost depends on the cap, not on how fast an agent prints. A few rules keep it low:

- Notifications reach the main thread in batches, and repeated output notifications of one pane in a batch count once.
- A pane has at most one capture in flight. Output that arrives during a capture schedules one more capture after it.
- The colour codes (SGR) of a capture are parsed off the main thread. A capture identical to the previous one does not touch the interface.
- An AppKit view draws the lines of the Output tab. SwiftUI does not recompute the layout when a new capture arrives.

### Hidden panes: activity and waiting prompts

A paused pane sends no output notifications, but the app still needs two facts about it: whether the agent is active, and whether it waits for a human. For this the app subscribes to each pane's history size and cursor line (`refresh-client -B`). tmux reports a change of a subscription at most once a second, paused or not (checked on tmux 3.6b). The first report after subscribing is ignored, because it is the starting value, not activity. A second subscription reports when a pane's process exits.

Each time a hidden pane is active, the app captures its screen, but not more often than once in 3 seconds per pane. It looks for two prompts in the tail:

- the folder-trust prompt of Claude Code, in the last 40 lines;
- a permission prompt or another multiple-choice question, in the last 15 lines.

The permission patterns are the same that `team status --json` uses for its `waiting_human` field. So a permission prompt is also caught whenever `team status` runs next. The trust markers belong to the app only.

An agent that already sits on a prompt prints nothing, so it sends no activity. For this case the app also captures every agent pane of the project once, hidden or not: when it connects to the project and when a new pane appears, and a hidden pane once more 3 seconds later. A prompt that was on screen before the app opened is therefore found right away.

The activity reports also drive an agent's state label: an agent with no output for 2 minutes reads «тихо N мин» (quiet for N minutes) instead of «работает» (working). Before the first output, the app takes the quiet time from `idle_s` in `team status`.

### Other projects

tmux does not send pane notifications for sessions the client is not attached to: splitting or killing a pane there produces at most `%window-pane-changed` (checked on tmux 3.6b). So the app re-reads the session and pane lists with `list-sessions` and `list-panes` over the channel in two cases: on any notification that sessions, windows or panes changed, merged over 0.3 seconds, and once a minute. The agent counts of other projects in the sidebar come from these lists.

## When the app calls `team`

Each `team` call is a process; a `team status` call costs about 0.1 seconds of CPU. The app therefore calls `team` on events, and limits the frequent one. The app learns about file changes from FSEvents on `.team/` and `agents/`, merged over 0.3 seconds.

| Command                       | When                                                                                                                                                                                                           | Limit                                                                        |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `team status --json`          | project opened or returned to; a file changed in `agents/` or in `.team/` other than the event log, handoffs and built instructions; panes appeared or closed; an agent started or stopped waiting for a human | once per 15 seconds; a trigger inside the 15 seconds is delayed, not dropped |
| `team status --json`          | after your action: spawn, up, restart, stop, role edit                                                                                                                                                         | none, runs at once                                                           |
| `team roles --json --library` | project opened; a file changed in `agents/` or `.team/build/`; after your action                                                                                                                               | none                                                                         |
| `team handoffs --json`        | project opened; a file changed in `.team/handoffs/`; after spawn, up, restart or stop                                                                                                                          | none                                                                         |
| `team check --json`           | project opened; the «team check» button on the Roles screen                                                                                                                                                         | none                                                                         |
| `team reap --json [--keep …]`   | once a minute for every project whose team has a live tmux session, open in the app or not, whatever the app has parsed from `team.yaml` (with `idle_stop_minutes: off` the CLI itself does nothing); the previous call must have finished. A project without a live session is skipped. The loop starts when the app launches. For an open project `--keep <manager>` is passed only while the manager has a queue, or a draft or pictures in its input box; for a project that is not open `--keep` is empty and the app creates no project model. After it stops agents in an open project, the app refreshes `status` | one minute; an error is only logged |
| `team --version`, `team status --help` | Settings opened or `toolPath` changed; the Environment window | none |

Your actions call `team spawn`, `team up`, `team restart [--fresh]` (Restore role calls it without `--fresh`), `team down [agent]`, `team role set` (including `--start` from the switch on the Roles screen), `team role new [--extends]` and `team log owner`, `team reap` (once a minute) and `team set idle_stop_minutes` (from the auto-stop cell).

The app does not call `team events` or `team task`. Besides the Claude Code transcripts and command files described above, it reads these files itself:

- **The event log.** The app follows the end of `.team/events.jsonl` with kqueue: it reads the last 1 MB on opening, then each new line, and keeps the newest 2,000 events.
- **`agents/team.yaml`**, for the strip on the Roles screen (layout, manager, tracker, worktree root, `idle_stop_minutes`; without the key the app shows the default, 15).
- **`.team/statusline.json`**, for the usage limits.
- **`.team/state.json`**, for the manager's session id before `team status` answers.

## Load

The app has these repeating timers, all one minute long:

- while connected, re-reading the session and pane lists over the channel;
- while a tmux server runs without `team-*` sessions, `tmux -N list-sessions`;
- `team reap --json` for each project with a live team session, one process per project per minute;
- reading the usage limits for the sidebar, two small files.

Everything else that touches tmux, `team` or files waits for an event: tmux notifications, kqueue and FSEvents. The interface also redraws a few time-based labels on its own clock, without starting processes or reading files: the queue marks every 10 seconds, the time since `team check` every 30 seconds, and an agent's running time and the journal every minute. The short delays in the sections above (0.3 seconds to merge notifications, the capture caps, 3 seconds for hidden panes, 15 seconds for `team status`) run only after such an event. A process the app starts is killed after a time limit: 60 seconds for `team` commands, 10 seconds for `team --version` and `--help`.

The figures below come from a live team on an Apple Silicon Mac with macOS 26, when agent panes showed the tail of the agent's terminal. Each measurement takes the CPU time of the app process and of the tmux server from `ps -o time` at the start and at the end of a 60-second window. A logging wrapper around `team` counted the app's `team` calls.

| State                            | App               | tmux server                                                                   |
|----------------------------------|-------------------|-------------------------------------------------------------------------------|
| Team screen, two agents printing | 4.3 % of one core | about 0.1 s more CPU time over the 60 s than without the app: 0.21 s → 0.32 s |
| Window hidden                    | about 0           | not measured separately                                                       |

**[нужен источник: замер нагрузки на нынешнем экране «Команда», где панели показывают тред из транскрипта, а чат следит за панелью менеджера во время хода, — у app-developer]**

The largest costs found were the ligatures of JetBrains Mono, shaped by CoreText, and SwiftUI recomputing the layout. So the monospaced font has ligatures and contextual alternates turned off, an AppKit view draws terminal lines, and colour codes are parsed off the main thread.

## Limitations

- The app does not use the network. It shows a task's title and number from `team`, but not the task's state in the tracker: the `team` contract does not have it.
- With a `team` that has no `--json` commands, the app works in a reduced mode. Instead of the agents it shows a message asking for a `team` with `--json`; the role screens and `team check` show errors too. The chat and the journal still work. For the chat, the app finds the manager's pane by the `@team_role` option that `team` sets on every agent pane and opens the newest transcript in that pane's directory. Only this mode guesses the transcript this way, because another Claude session in the same directory can be newer.
- With a `team` whose `status --json` has no `task` and `dirty` fields, an agent's task comes from the latest event with a task in the log, and the uncommitted-change count comes from the app's own `git --no-optional-locks status --porcelain` in the agent's directory.
- The app needs tmux 3.2 or newer: it uses `-N`, pane subscriptions and output pausing in control mode. Its tmux behaviour was checked on tmux 3.6b.
- The app does not show an agent's context size (`ctx`) or the reset flags (`reset_due`, `context_warning`) from `team status --json`; the manager uses them.
- The app answers no agent's prompts. Trust and permission prompts of agents are answered in Terminal attached to the pane. Only the manager's prompts can be answered in the app, in [the Claude Code line](#the-claude-code-line).

## For contributors

The Swift package has two targets:

- `AgentTeamCore` is a library with no interface: the tmux client and its parser, the `team` calls and their JSON models, the transcript parser, file watchers, settings and themes.
- `AgentTeamApp` is the SwiftUI application.

The package needs macOS 14 and uses only system frameworks: Foundation, Observation, CoreServices, CoreText, CoreGraphics, ImageIO, UniformTypeIdentifiers, QuartzCore, AppKit and SwiftUI. Run the tests from `app/`:

```bash
swift test
```

Contract tests decode JSON fixtures in `app/Tests/AgentTeamCoreTests/Fixtures/`. Integration tests start their own tmux server on a separate socket (`tmux -L agtest-…`), so they do not touch your sessions.

For screenshots and checks, the app binary takes launch options:

| Option                                        | Effect                                                                                                                       |
|-----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| `--project <name>`                            | select project `team-<name>`                                                                                                 |
| `--screen <screen>`                           | open `manager`, `agent`, `roles`, `roletech`, `handoffs`, `composition`, `journal`, `settings`, `environment` or `collapsed` |
| `--agent <agent>`                             | the agent for `--screen agent`                                                                                               |
| `--role <role>`                               | the role for `roles`, `roletech` and `composition`                                                                           |
| `--socket <name>`                             | the tmux server, as `tmux -L <name>`                                                                                         |
| `--snapshot <file.png>`                       | save a picture of the window after `--snapshot-delay` seconds (6 by default)                                                 |
| `--quit`                                      | quit after the snapshot                                                                                                      |
| `--app-theme`, `--chat-theme`, `--term-theme` | use a theme for this run without saving it                                                                                   |

More options exist for scripted checks: `--timing`, `--bench`, `--bench-rounds`, `--bench-stay`, `--roles-json`, `--role-shared`, `--expand-parent`, `--add-role`, `--tool`, `--repo`, `--sidebar`, `--columns`, `--agents-width`, `--chat-spacing`, `--chat-spacing-then`, `--feed-hide`, `--feed-hide-then`, `--view-image`, `--pending`, `--pending-lost`, `--pending-held`, `--pending-stopped` and `--draft-image=<file>`. They are read in `app/Sources/AgentTeamApp/App.swift`; most work only together with `--snapshot` or `--bench`. Such a run keeps its settings in a temporary defaults domain that is deleted on exit, so it does not change your settings.

The app keeps its settings in user defaults:

- `toolPath` and `tmuxSocket`;
- `projects` (directories added by hand) and `hiddenProjects`;
- `selectedSession` and `sidebarCollapsed`;
- `teamAgentsWidth` and `teamAgentColumns`;
- `displaySettings`: one JSON value with the fonts, sizes, spacings, the three themes and the feed switches;
- `draft.<repo>`: the unsent chat message of a project.
