import os
import shutil
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


@pytest.fixture(autouse=True)
def _isolated_claude_projects(tmp_path, monkeypatch):
    """Транскрипты, реестр сессий и конфиг Claude Code — во временных каталогах: тесты не читают настоящие
    ~/.claude/projects, ~/.claude/sessions и ~/.claude.json."""
    monkeypatch.setenv("TEAM_PROJECTS_DIR", str(tmp_path / "claude-projects"))
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(tmp_path / "claude-sessions"))
    monkeypatch.setenv("TEAM_JOBS_DIR", str(tmp_path / "claude-jobs"))             # фоновые задачи (roleguard.py)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "claude-config"))   # доверие к каталогам (trust.py)
    from agent_team import cli
    monkeypatch.setattr(cli, "ADDR_WAIT_S", 0)         # restart --fresh не ждёт регистрации сессии, которой у cat нет


def kill_tmux_socket(label):
    """Останавливает сервер tmux на сокете теста и удаляет файл сокета: kill-server его не убирает."""
    subprocess.run(["tmux", "-L", label, "kill-server"], capture_output=True)
    base = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}"
    (base / label).unlink(missing_ok=True)


def pytest_configure(config):
    config.addinivalue_line("markers", "both_layouts: тест идёт в обеих раскладках tmux (windows и panes); без метки — только windows")
    config.addinivalue_line("markers", "panes_only: тест идёт только в раскладке panes")


def pytest_generate_tests(metafunc):
    """Раскладка tmux: по умолчанию windows; обе — у тестов с меткой both_layouts, только panes — с panes_only."""
    if "layout" not in metafunc.fixturenames:
        return
    if metafunc.definition.get_closest_marker("both_layouts"):
        metafunc.parametrize("layout", ["windows", "panes"], indirect=True)
    elif metafunc.definition.get_closest_marker("panes_only"):
        metafunc.parametrize("layout", ["panes"], indirect=True)


@pytest.fixture
def layout(request):
    return getattr(request, "param", "windows")


@pytest.fixture(scope="session")
def _project_template(tmp_path_factory):
    """Репозиторий проекта собирается один раз за сессию, тесты получают копию: git init/add/commit — три подпроцесса на тест."""
    repo = tmp_path_factory.mktemp("template") / "proj"
    (repo / "agents" / "roles").mkdir(parents=True)
    (repo / "agents" / "shared").mkdir()
    (repo / "agents" / "roles" / "boss.md").write_text(BOSS, encoding="utf-8")
    (repo / "agents" / "roles" / "worker.md").write_text(WORKER, encoding="utf-8")
    (repo / "agents" / "roles" / "idle.md").write_text(IDLE, encoding="utf-8")
    (repo / "agents" / "shared" / "rules.md").write_text("# Правила\nНе ломать.\n", encoding="utf-8")
    (repo / "agents" / "team.yaml").write_text("placeholder\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], check=True)
    return repo


@pytest.fixture
def project(layout, _project_template, tmp_path, monkeypatch):
    """Мини-проект с git-репозиторием и описанием команды: своя копия шаблона на каждый тест."""
    repo = tmp_path / "proj"
    shutil.copytree(_project_template, repo, symlinks=True)
    name = "t" + uuid.uuid4().hex[:6]
    (repo / "agents" / "team.yaml").write_text(TEAM_YAML.format(project=name, repo=repo, layout=layout), encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "team.yaml"], check=True)
    monkeypatch.chdir(repo)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    monkeypatch.setenv("TEAM_TMUX_SOCKET", "teamtest-" + name)
    yield repo
    kill_tmux_socket("teamtest-" + name)


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


@pytest.fixture
def multi_project(layout, tmp_path, monkeypatch):
    """Корень без git, внутри два репозитория; у каждого исполнителя worktree от своего."""
    root = tmp_path / "work"
    (root / "agents" / "roles").mkdir(parents=True)
    name = "m" + uuid.uuid4().hex[:6]
    (root / "agents" / "team.yaml").write_text(MULTI_YAML.format(project=name, layout=layout), encoding="utf-8")
    (root / "agents" / "roles" / "boss.md").write_text(BOSS.replace("includes: [rules.md]\n", ""), encoding="utf-8")
    for role in ("de", "back"):
        (root / "agents" / "roles" / f"{role}.md").write_text(MULTI_ROLE.format(name=role), encoding="utf-8")
        _git_repo(root / f"{role}-repo")
    monkeypatch.chdir(root)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    monkeypatch.setenv("TEAM_TMUX_SOCKET", "teamtest-" + name)
    yield root
    kill_tmux_socket("teamtest-" + name)
