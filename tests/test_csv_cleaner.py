import pandas as pd
from python.data.csv_cleaner import clean
 
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


def test_bad_dates_are_rejected():
    df = pd.DataFrame({"name": ["Ann", "Bob"], "signup": ["2024-01-05", "not a date"]})
    good, _, bad = clean(df, date_column="signup")
    assert list(good["signup"]) == ["2024-01-05"]
    assert list(bad["name"]) == ["Bob"]