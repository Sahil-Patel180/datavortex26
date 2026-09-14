import sys
from pathlib import Path
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import src.clean as clean  # noqa: E402
import src.features as feat  # noqa: E402

@pytest.mark.parametrize("value", ["", " ", "NULL", "null", "N/A", "nan", "-", None])
def test_sentinels_detected(value):
    assert clean.is_sentinel(value)

@pytest.mark.parametrize("value", ["Nike", "0", "NULLIFY", "not null here"])
def test_real_values_not_sentinels(value):
    assert not clean.is_sentinel(value)

def test_strips_html_tags():
    assert clean.clean_text("Great product<br>") == "Great product"
    assert clean.clean_text("Nice<div>") == "Nice"

def test_unescapes_entities():
    assert clean.clean_text("Fashion&amp;Style") == "Fashion&Style"

def test_repairs_mojibake():
    assert clean.clean_text("CafÃ© visit") == "Café visit"

def test_leaves_clean_unicode_alone():
    assert clean.clean_text("Café visit") == "Café visit"

def test_squashes_whitespace_and_trims():
    assert clean.clean_text("  too   many spaces  ") == "too many spaces"

@pytest.mark.parametrize("disguised", ["NULL", "NULL<div>", "NULL<br>", "NULL\n\n", "  NULL  "])
def test_disguised_sentinels_become_na(disguised):
    # Only the SECOND sentinel pass (after markup stripping) catches these.
    assert pd.isna(clean.clean_text(disguised))

def test_parses_all_three_formats_to_same_type():
    assert clean.parse_timestamp("1722528840") == pd.Timestamp("2024-08-01 16:14:00")
    assert clean.parse_timestamp("25-09-2024") == pd.Timestamp("2024-09-25")
    assert clean.parse_timestamp("2025-04-13T20:12:18") == pd.Timestamp("2025-04-13 20:12:18")

def test_day_first_not_month_first():
    # 25 cannot be a month; proves the dd-mm-yyyy reading.
    assert clean.parse_timestamp("25-09-2024").month == 9

def test_format_detection_labels():
    assert clean.detect_ts_format("1722528840") == "unix_seconds"
    assert clean.detect_ts_format("25-09-2024") == "dd_mm_yyyy"
    assert clean.detect_ts_format("2025-04-13T20:12:18") == "iso8601"

def test_negative_likes_nulled_not_absolute():
    s = pd.Series([-4987, 100], dtype="Int64")
    out = clean.null_impossible(s, 5000)
    assert pd.isna(out.iloc[0])
    assert out.iloc[1] == 100

def test_group_median_imputation_flags_rows():
    frame = pd.DataFrame(
        {
            "platform": ["Reddit", "Reddit", "Reddit", "Twitter", "Twitter"],
            "likes": pd.array([10, 20, None, 1000, None], dtype="Int64"),
        }
    )
    filled, flag = clean.impute_by_group(frame, "likes", ["platform"])
    assert filled.iloc[2] == 15          # Reddit median, not global
    assert filled.iloc[4] == 1000        # Twitter median
    assert list(flag) == [False, False, True, False, True]

def test_missing_platform_is_unknown_never_inferred():
    assert clean.canon_platform("") == "Unknown"
    assert clean.canon_platform("NULL") == "Unknown"
    assert clean.canon_platform("reddit") == "Reddit"

def test_location_split():
    out = clean.split_location(pd.Series(["Berlin, Germany", "Dubai, UAE"]))
    assert list(out["city"]) == ["Berlin", "Dubai"]
    assert list(out["country"]) == ["Germany", "UAE"]

def test_duplicate_post_ids_dropped_keeping_first():
    frame = pd.DataFrame({"post_id": ["a", "b", "a"], "v": [1, 2, 1]})
    kept, removed = clean.drop_duplicate_posts(frame)
    assert list(kept["post_id"]) == ["a", "b"]
    assert len(removed) == 1

def test_hashtag_extraction_deduplicates():
    assert feat.extract_hashtags("#Tech, #tech #Food") == ["tech", "food"]

def test_brand_resolved_through_product_catalogue():
    assert feat.extract_brand("Comparing Google Chromebook to the competition.") == "Google"
    assert feat.extract_brand("My new Air Max from Nike!") == "Nike"

def test_contradiction_detected():
    text = "Bummed out with my new Air Max from Nike! Absolutely loving it."
    assert feat.is_contradictory(feat.score_opener(text), feat.score_verdict(text))

def test_consistent_post_not_flagged():
    text = "Thrilled with my new Air Max from Nike! Absolutely loving it."
    assert not feat.is_contradictory(feat.score_opener(text), feat.score_verdict(text))

def test_neutral_verdict_never_contradicts():
    text = "Bummed out with my new Air Max from Nike! It's okay."
    assert not feat.is_contradictory(feat.score_opener(text), feat.score_verdict(text))
