import pandas as pd
import pytest

from python.data.csv_cleaner import clean, csv_lines, main


@pytest.fixture
def signups():
    """Two people: one with a good date, one with a date that cannot be parsed."""
    return pd.DataFrame(
        {"name": ["Ann", "Bob"], "signup": ["2024-01-05", "not a date"]}
    )


def test_clean_separates_duplicates_and_missing():
    df = pd.DataFrame(
        {
            "name": ["Ann", "Bob", "Ann", "Cy"],
            "city": ["Paris", "Rome", "Paris", None],
        }
    )
    good, duplicates, bad = clean(df)
    assert list(good["name"]) == ["Ann", "Bob"]
    assert list(duplicates.index) == [2]
    assert list(bad["name"]) == ["Cy"]


def test_bad_dates_are_rejected(signups):
    good, _, bad = clean(signups, date_column="signup")
    assert list(good["signup"]) == ["2024-01-05"]
    assert list(bad["name"]) == ["Bob"]
    assert bad["signup"].isna().all()


def test_dates_are_standardized_before_duplicate_detection():
    df = pd.DataFrame(
        {"name": ["Ann", "Ann"], "signup": ["2024-01-05", "2024/01/05"]}
    )

    good, duplicates, bad = clean(df, date_column="signup")

    assert list(good["signup"]) == ["2024-01-05"]
    assert list(duplicates.index) == [1]
    assert bad.empty


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("2027/03/20", "2027-03-20"),
        ("September 23, 2027", "2027-09-23"),
        ("12/21/2027", "2027-12-21"),
    ],
)
def test_supported_input_date_formats(raw, expected):
    df = pd.DataFrame({"name": ["x"], "d": [raw]})
    good, _, _ = clean(df, date_column="d")
    assert list(good["d"]) == [expected]


@pytest.mark.parametrize(
    "date_format, expected",
    [
        ("YYYY/MM/DD", "2027/03/03"),
        ("MM/DD/YYYY", "03/03/2027"),
        ("Month D, YYYY", "March 3, 2027"),  # no leading zero on the day
    ],
)
def test_output_date_formats(date_format, expected):
    df = pd.DataFrame({"name": ["x"], "d": ["2027-03-03"]})
    good, _, _ = clean(df, date_column="d", date_format=date_format)
    assert list(good["d"]) == [expected]


def test_invalid_date_format_is_rejected(signups):
    with pytest.raises(ValueError, match="unsupported date_format"):
        clean(signups, date_column="signup", date_format="nonsense")


def test_input_dataframe_unchanged(signups):
    before = signups.copy()
    clean(signups, date_column="signup")
    pd.testing.assert_frame_equal(signups, before)


def test_csv_lines_counts_header_and_one_based_rows():
    # Row label 0 is line 2 of the file (line 1 is the header)
    assert csv_lines(pd.DataFrame(index=[0, 3])) == "2, 5"


def test_input_output_same_path(tmp_path, monkeypatch, capsys):
    csv = tmp_path / "data.csv"
    csv.write_text("name\nAnn\n")
    monkeypatch.setattr("sys.argv", ["csv_cleaner", str(csv), "-o", str(csv)])
    assert main() == 1
    assert "different file" in capsys.readouterr().err
    assert csv.read_text() == "name\nAnn\n"  # input left untouched


def test_missing_date_column_is_an_error(tmp_path, monkeypatch, capsys):
    csv = tmp_path / "data.csv"
    csv.write_text("name\nAnn\n")
    monkeypatch.setattr("sys.argv", ["csv_cleaner", str(csv), "--date-column", "nope"])
    assert main() == 1
    assert "no column named" in capsys.readouterr().err


def test_stale_rejected_file_is_removed_when_no_rows_are_rejected(
    tmp_path, monkeypatch, capsys
):
    csv = tmp_path / "data.csv"
    rejected = tmp_path / "data.rejected.csv"
    csv.write_text("name\nAnn\n")
    rejected.write_text("name\nOld rejected row\n")
    monkeypatch.setattr("sys.argv", ["csv_cleaner", str(csv)])

    assert main() == 0
    assert not rejected.exists()
    capsys.readouterr()
