import subprocess
import uuid
from pathlib import Path

import pytest

TEAM_YAML = """\
project: {project}
repo: {repo}
worktree_root: ../wt
layout: {layout}
test_command: .venv/bin/python -m pytest
manager: boss
roles:
  - {{role: boss, start: manual}}
  - {{role: worker, start: always}}
  - {{role: idle, start: on_demand}}
"""

BOSS = """\
---
role: boss
title: Босс
kind: manager
includes: [rules.md]
allow: [mcp__tracker]
---
Ты менеджер.
"""

WORKER = """\
---
role: worker
title: Исполнитель
kind: executor
worktree: {dir: worker, branch: worker}
includes: [rules.md]
add_dirs: ["~/docs"]
---
Ты исполнитель.
"""

IDLE = """\
---
role: idle
title: Простой
kind: executor
---
Ждёшь.
"""


@pytest.fixture(params=["windows", "panes"])
def project(request, tmp_path, monkeypatch):
    """Мини-проект с git-репозиторием и описанием команды."""
    repo = tmp_path / "proj"
    (repo / "agents" / "roles").mkdir(parents=True)
    (repo / "agents" / "shared").mkdir()
    name = "t" + uuid.uuid4().hex[:6]
    (repo / "agents" / "team.yaml").write_text(TEAM_YAML.format(project=name, repo=repo, layout=request.param), encoding="utf-8")
    (repo / "agents" / "roles" / "boss.md").write_text(BOSS, encoding="utf-8")
    (repo / "agents" / "roles" / "worker.md").write_text(WORKER, encoding="utf-8")
    (repo / "agents" / "roles" / "idle.md").write_text(IDLE, encoding="utf-8")
    (repo / "agents" / "shared" / "rules.md").write_text("# Правила\nНе ломать.\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], check=True)
    monkeypatch.chdir(repo)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    yield repo
    subprocess.run(["tmux", "kill-session", "-t", f"=team-{name}"], capture_output=True)


MULTI_YAML = """\
project: {project}
worktree_root: wt
layout: {layout}
manager: boss
roles:
  - {{role: boss, start: manual}}
  - {{role: de, start: always}}
  - {{role: back, start: always}}
"""

MULTI_ROLE = """\
---
role: {name}
title: {name}
kind: executor
worktree: {{repo: {name}-repo, dir: {name}, branch: {name}}}
---
Ты исполнитель.
"""


def _git_repo(path):
    path.mkdir(parents=True)
    (path / "README.md").write_text("x\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], check=True)


@pytest.fixture(params=["windows", "panes"])
def multi_project(request, tmp_path, monkeypatch):
    """Корень без git, внутри два репозитория; у каждого исполнителя worktree от своего."""
    root = tmp_path / "work"
    (root / "agents" / "roles").mkdir(parents=True)
    name = "m" + uuid.uuid4().hex[:6]
    (root / "agents" / "team.yaml").write_text(MULTI_YAML.format(project=name, layout=request.param), encoding="utf-8")
    (root / "agents" / "roles" / "boss.md").write_text(BOSS.replace("includes: [rules.md]\n", ""), encoding="utf-8")
    for role in ("de", "back"):
        (root / "agents" / "roles" / f"{role}.md").write_text(MULTI_ROLE.format(name=role), encoding="utf-8")
        _git_repo(root / f"{role}-repo")
    monkeypatch.chdir(root)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    yield root
    subprocess.run(["tmux", "kill-session", "-t", f"=team-{name}"], capture_output=True)
