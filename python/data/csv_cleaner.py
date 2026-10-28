# Goal
# Removes duplicates, standardizes data formats, and flags missing values in a messy data file.

# Checklist
# Read messy CSV input files (via standard library or pandas)
# Identify and drop duplicate rows reliably
# Standardize date strings or malformed records
# Log or isolate lines containing empty/null target properties

import os
import pandas as pd

FILENAME = "python\\data\\data.csv"
summary = "=== SUMMARY ===\n"

def read_csv_files():
    summaryPart = "Duplicates: "

    df = pd.read_csv(FILENAME)
    duplicates = df.duplicated()

    for i, row in df.iterrows():
        if (duplicates[i] == True):
            print("There is a duplicate in row", i)
            summaryPart += str(i) + ","
            print(row)

    summaryPart = summaryPart[:-1]
    return summaryPart

summary += read_csv_files()
print(summary)