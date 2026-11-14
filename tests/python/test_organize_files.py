import os
import time

import pytest

from python.files.organize_files import (
    apply_moves,
    destination_folder,
    main,
    plan_moves,
    unique_destination,
)


def make(folder, name, content=b"x"):
    path = folder / name
    path.write_bytes(content)
    return path


@pytest.mark.parametrize(
    "name, expected",
    [
        ("photo.jpg", "jpg"),
        ("PHOTO.JPG", "jpg"),  # same folder as .jpg
        ("README", "no-extension"),
        ("archive.tar.gz", "gz"),
    ],
)
def test_destination_folder_by_extension(tmp_path, name, expected):
    assert destination_folder(make(tmp_path, name), "extension") == expected


def test_destination_folder_by_date_uses_the_modification_month(tmp_path):
    path = make(tmp_path, "a.txt")
    march = time.mktime((2026, 3, 15, 12, 0, 0, 0, 0, -1))
    os.utime(path, (march, march))
    assert destination_folder(path, "date") == "2026-03"


def test_plan_sorts_files_by_extension(tmp_path):
    a = make(tmp_path, "a.jpg")
    b = make(tmp_path, "B.JPG")
    c = make(tmp_path, "notes.txt")
    d = make(tmp_path, "README")
    moves, skipped = plan_moves(tmp_path)
    assert moves == [
        (b, tmp_path / "jpg" / "B.JPG"),
        (d, tmp_path / "no-extension" / "README"),
        (a, tmp_path / "jpg" / "a.jpg"),
        (c, tmp_path / "txt" / "notes.txt"),
    ]
    assert skipped == []


def test_planning_moves_nothing(tmp_path):
    make(tmp_path, "a.jpg")
    plan_moves(tmp_path)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["a.jpg"]


def test_subfolders_hidden_files_and_symlinks_are_ignored(tmp_path):
    (tmp_path / "already").mkdir()
    make(tmp_path / "already", "inside.txt")
    make(tmp_path, ".hidden.txt")
    real = make(tmp_path, "real.txt")
    try:
        os.symlink(real, tmp_path / "link.txt")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not available here")
    moves, _ = plan_moves(tmp_path)
    assert [source.name for source, _ in moves] == ["real.txt"]


def test_unique_destination_never_returns_an_existing_file(tmp_path):
    existing = make(tmp_path, "photo.jpg")
    assert unique_destination(existing, set()) == tmp_path / "photo (1).jpg"


def test_unique_destination_avoids_names_already_planned(tmp_path):
    wanted = tmp_path / "photo.jpg"
    taken = {wanted, tmp_path / "photo (1).jpg"}
    assert unique_destination(wanted, taken) == tmp_path / "photo (2).jpg"


def test_plan_never_overwrites_or_double_books_a_destination(tmp_path):
    (tmp_path / "jpg").mkdir()
    existing = make(tmp_path / "jpg", "a.jpg", b"keep me")
    make(tmp_path, "a.jpg")
    make(tmp_path, "a (1).jpg")
    moves, _ = plan_moves(tmp_path)
    destinations = [destination for _, destination in moves]
    assert len(set(destinations)) == len(destinations)
    assert existing not in destinations


def test_a_file_in_the_way_of_a_folder_is_skipped_not_a_crash(tmp_path):
    make(tmp_path, "jpg")  # a plain file called "jpg"
    make(tmp_path, "x.jpg")
    moves, skipped = plan_moves(tmp_path)
    assert [path.name for path, _ in skipped] == ["x.jpg"]
    assert [path.name for path, _ in moves] == ["jpg"]  # it goes to no-extension/


def test_apply_moves_files_and_keeps_their_content(tmp_path):
    make(tmp_path, "a.jpg", b"picture")
    apply_moves(plan_moves(tmp_path)[0])
    assert (tmp_path / "jpg" / "a.jpg").read_bytes() == b"picture"
    assert not (tmp_path / "a.jpg").exists()


def test_running_twice_is_harmless(tmp_path):
    make(tmp_path, "a.jpg")
    apply_moves(plan_moves(tmp_path)[0])
    assert plan_moves(tmp_path)[0] == []


def test_cli_dry_run_moves_nothing(tmp_path, monkeypatch, capsys):
    make(tmp_path, "a.jpg")
    monkeypatch.setattr("sys.argv", ["organize_files", str(tmp_path)])
    assert main() == 0
    out = capsys.readouterr().out
    assert "DRY RUN" in out
    assert "a.jpg -> jpg/a.jpg" in out.replace("\\", "/")
    assert (tmp_path / "a.jpg").exists()


def test_cli_apply_moves_the_files(tmp_path, monkeypatch, capsys):
    make(tmp_path, "a.jpg")
    monkeypatch.setattr("sys.argv", ["organize_files", str(tmp_path), "--apply"])
    assert main() == 0
    assert "Moved 1 file(s)" in capsys.readouterr().out
    assert (tmp_path / "jpg" / "a.jpg").exists()


def test_cli_missing_folder_is_an_error(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["organize_files", str(tmp_path / "nope")])
    assert main() == 1
    assert "not a folder" in capsys.readouterr().err


def test_cli_bad_mode_is_a_usage_error(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.argv", ["organize_files", str(tmp_path), "--by", "size"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2
