import pytest

from python.files.duplicate_finder import find_duplicates, hash_file, main


def write(folder, name, content):
    path = folder / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def test_hash_file_matches_known_sha256(tmp_path):
    path = write(tmp_path, "abc.txt", b"abc")
    expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert hash_file(path) == expected


def test_identical_files_in_different_folders_are_grouped(tmp_path):
    a = write(tmp_path, "a.txt", b"hello world")
    b = write(tmp_path, "sub/copy.txt", b"hello world")
    groups, skipped = find_duplicates(tmp_path)
    assert groups == [sorted([a, b])]
    assert skipped == []


def test_same_size_but_different_content_is_not_a_duplicate(tmp_path):
    write(tmp_path, "one.txt", b"AAAA")
    write(tmp_path, "two.txt", b"BBBB")
    groups, _ = find_duplicates(tmp_path)
    assert groups == []


def test_unique_files_and_empty_files_are_ignored(tmp_path):
    write(tmp_path, "unique.txt", b"only one of me")
    write(tmp_path, "empty1.txt", b"")
    write(tmp_path, "empty2.txt", b"")
    groups, _ = find_duplicates(tmp_path)
    assert groups == []


def test_three_copies_form_one_group_and_other_files_stay_out(tmp_path):
    copies = [write(tmp_path, f"dir{i}/f.bin", b"x" * 100) for i in range(3)]
    write(tmp_path, "other.bin", b"y" * 100)
    groups, _ = find_duplicates(tmp_path)
    assert groups == [sorted(copies)]


def test_cli_reports_duplicates(tmp_path, monkeypatch, capsys):
    write(tmp_path, "a.txt", b"same")
    write(tmp_path, "b.txt", b"same")
    monkeypatch.setattr("sys.argv", ["duplicate_finder", str(tmp_path)])
    assert main() == 0
    out = capsys.readouterr().out
    assert "Group 1: 2 identical files, 4 bytes each" in out
    assert "1 redundant file(s) in 1 group(s); 4 bytes could be reclaimed" in out


def test_cli_with_no_duplicates(tmp_path, monkeypatch, capsys):
    write(tmp_path, "a.txt", b"one")
    monkeypatch.setattr("sys.argv", ["duplicate_finder", str(tmp_path)])
    assert main() == 0
    assert "No duplicate files found" in capsys.readouterr().out


def test_cli_missing_folder_is_an_error(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["duplicate_finder", str(tmp_path / "nope")])
    assert main() == 1
    assert "not a folder" in capsys.readouterr().err


def test_cli_without_a_folder_is_a_usage_error(monkeypatch):
    monkeypatch.setattr("sys.argv", ["duplicate_finder"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2