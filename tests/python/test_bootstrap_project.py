"""Tests for python/scaffolding/bootstrap_project.py (place in tests/python/)."""

import importlib.util
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "python"
    / "scaffolding"
    / "bootstrap_project.py"
)

spec = importlib.util.spec_from_file_location("bootstrap_project", SCRIPT)
bp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bp)

HAS_GIT = shutil.which("git") is not None

EXPECTED_FILES = [
    "README.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    ".gitignore",
    "LICENSE",
    "tests/test_smoke.py",
]


def run_main(monkeypatch, *args):
    """Call main() with the given command-line arguments and return its exit code."""
    monkeypatch.setattr(sys, "argv", ["bootstrap_project.py", *map(str, args)])
    return bp.main()


# --- build_plan / render ---


def test_render_fills_placeholders():
    text = bp.render("__NAME__ / __AUTHOR__ / __YEAR__", "demo", "Jane")
    assert text == f"demo / Jane / {date.today().year}"


def test_build_plan_has_expected_files():
    plan = bp.build_plan("demo", "Jane")
    for path in EXPECTED_FILES:
        assert path in plan


def test_build_plan_gitkeep_for_empty_dirs_only():
    plan = bp.build_plan("demo", "Jane")
    for directory in bp.DIRECTORIES:
        has_gitkeep = f"{directory}/.gitkeep" in plan
        assert has_gitkeep == (directory not in bp.NO_GITKEEP)


def test_build_plan_has_no_leftover_placeholders():
    plan = bp.build_plan("demo", "Jane")
    for path, content in plan.items():
        assert "__NAME__" not in content, path
        assert "__AUTHOR__" not in content, path
        assert "__YEAR__" not in content, path


def test_license_contains_year_and_author():
    plan = bp.build_plan("demo", "Jane Doe")
    assert f"Copyright (c) {date.today().year} Jane Doe" in plan["LICENSE"]


# --- write_files ---


def test_write_files_creates_files(tmp_path):
    bp.write_files(tmp_path, {"a/b.txt": "hello"}, dry_run=False)
    assert (tmp_path / "a" / "b.txt").read_text(encoding="utf-8") == "hello"


def test_write_files_never_overwrites(tmp_path, capsys):
    target = tmp_path / "README.md"
    target.write_text("mine", encoding="utf-8")
    bp.write_files(tmp_path, {"README.md": "template"}, dry_run=False)
    assert target.read_text(encoding="utf-8") == "mine"
    assert "skipped README.md" in capsys.readouterr().out


def test_write_files_dry_run_changes_nothing(tmp_path, capsys):
    bp.write_files(tmp_path, {"a/b.txt": "hello"}, dry_run=True)
    assert list(tmp_path.iterdir()) == []
    assert "would create a/b.txt" in capsys.readouterr().out


# --- main ---


def test_main_creates_full_structure(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    assert run_main(monkeypatch, project, "--no-git") == 0
    for path in EXPECTED_FILES:
        assert (project / path).is_file(), path
    for directory in bp.DIRECTORIES:
        assert (project / directory).is_dir(), directory
    assert not (project / ".git").exists()


def test_main_uses_folder_name_by_default(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    run_main(monkeypatch, project, "--no-git")
    assert (project / "README.md").read_text(encoding="utf-8").startswith("# my-app")


def test_main_name_and_author_options(tmp_path, monkeypatch):
    project = tmp_path / "x"
    run_main(
        monkeypatch, project, "--no-git", "--name", "Cool Tool", "--author", "Jane"
    )
    assert (project / "README.md").read_text(encoding="utf-8").startswith("# Cool Tool")
    assert "Jane" in (project / "LICENSE").read_text(encoding="utf-8")


def test_main_dry_run_creates_nothing(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    assert run_main(monkeypatch, project, "--dry-run") == 0
    assert not project.exists()


def test_main_rerun_keeps_existing_files(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    run_main(monkeypatch, project, "--no-git")
    (project / "README.md").write_text("edited", encoding="utf-8")
    assert run_main(monkeypatch, project, "--no-git") == 0
    assert (project / "README.md").read_text(encoding="utf-8") == "edited"


def test_main_rejects_a_file_path(tmp_path, monkeypatch, capsys):
    not_a_folder = tmp_path / "file.txt"
    not_a_folder.write_text("hi", encoding="utf-8")
    assert run_main(monkeypatch, not_a_folder) == 1
    assert "not a folder" in capsys.readouterr().err


@pytest.mark.skipif(not HAS_GIT, reason="git not installed")
def test_main_initializes_git_repo(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    assert run_main(monkeypatch, project) == 0
    assert (project / ".git").is_dir()


def test_init_git_reports_missing_git(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(bp.shutil, "which", lambda _name: None)
    assert bp.init_git(tmp_path, dry_run=False) is False
    assert "git is not installed" in capsys.readouterr().err


def test_init_git_reports_failure(tmp_path, monkeypatch, capsys):
    def fail(*_args, **_kwargs):
        raise subprocess.CalledProcessError(1, "git", stderr="boom")

    monkeypatch.setattr(bp.shutil, "which", lambda _name: "/usr/bin/git")
    monkeypatch.setattr(bp.subprocess, "run", fail)
    assert bp.init_git(tmp_path, dry_run=False) is False
    assert "git init failed: boom" in capsys.readouterr().err


# --- generated .gitignore actually works ---


@pytest.mark.skipif(not HAS_GIT, reason="git not installed")
def test_gitignore_rules_work(tmp_path, monkeypatch):
    project = tmp_path / "my-app"
    run_main(monkeypatch, project)

    def ignored(path):
        result = subprocess.run(
            ["git", "check-ignore", "-q", path],
            cwd=project,
            capture_output=True,
            check=False,
        )
        return result.returncode == 0

    assert ignored(".env")
    assert not ignored(".env.example")
    assert ignored(".vscode/settings.json")
    assert not ignored(".vscode/extensions.json")
