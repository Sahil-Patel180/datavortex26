from __future__ import annotations
import re
import numpy as np
import pandas as pd
from config import (
    BRANDS,
    NEUTRAL_TAIL,
    OPENER_LEXICON,
    PRODUCT_TO_BRAND,
    SENTIMENT_LABELS,
    VERDICT_LEXICON,
)

_HASHTAG_RE = re.compile(r"#(\w+)")
_MENTION_RE = re.compile(r"@(\w+)")
_BRAND_RE = re.compile(r"\b(" + "|".join(map(re.escape, BRANDS)) + r")\b")
_PRODUCT_RE = re.compile(
    r"\b(" + "|".join(sorted(map(re.escape, PRODUCT_TO_BRAND), key=len, reverse=True)) + r")\b"
)

def extract_hashtags(text) -> list[str]:
    if pd.isna(text):
        return []
    seen, out = set(), []
    for tag in _HASHTAG_RE.findall(str(text)):
        key = tag.lower()
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out

def extract_mentions(text) -> list[str]:
    if pd.isna(text):
        return []
    return sorted({m.lower() for m in _MENTION_RE.findall(str(text))})

def extract_brand(text):
    if pd.isna(text):
        return pd.NA
    product = _PRODUCT_RE.search(str(text))
    if product:
        return PRODUCT_TO_BRAND[product.group(1)]
    brand = _BRAND_RE.search(str(text))
    return brand.group(1) if brand else pd.NA

def extract_product(text):
    if pd.isna(text):
        return pd.NA
    hit = _PRODUCT_RE.search(str(text))
    return hit.group(1) if hit else pd.NA

def _strip_tail(text: str) -> str:
    return text.replace(NEUTRAL_TAIL, " ")

def score_verdict(text):
    if pd.isna(text):
        return pd.NA
    low = _strip_tail(str(text).lower())
    for phrase, polarity in VERDICT_LEXICON.items():
        if phrase in low:
            return polarity
    return pd.NA

def score_opener(text):
    if pd.isna(text):
        return pd.NA
    low = _strip_tail(str(text).lower())
    head = low[:40]
    for phrase, polarity in OPENER_LEXICON.items():
        if phrase in head:
            return polarity
    return pd.NA

def sentiment_label(verdict):
    if pd.isna(verdict):
        return pd.NA
    return SENTIMENT_LABELS[int(verdict)]

def is_contradictory(opener, verdict) -> bool:
    if pd.isna(opener) or pd.isna(verdict):
        return False
    return int(opener) * int(verdict) < 0

def add_engagement(frame: pd.DataFrame) -> pd.DataFrame:
    out = frame.copy()
    out["engagement"] = (
        out["likes"].fillna(0) + out["shares"].fillna(0) + out["comments"].fillna(0)
    ).astype("Int64")
    out["engagement_rate"] = (
        out["engagement"].astype("Float64") / out["follower_count"].replace(0, pd.NA)
    )
    out["shares_exceed_likes"] = (
        out["shares"].fillna(0) > out["likes"].fillna(0)
    ) & out["likes"].notna()
    return out

def add_temporal(frame: pd.DataFrame, ts_col: str = "posted_at") -> pd.DataFrame:
    out = frame.copy()
    ts = pd.to_datetime(out[ts_col])
    out["post_date"] = ts.dt.date
    out["post_year"] = ts.dt.year.astype("Int64")
    out["post_month"] = ts.dt.to_period("M").astype(str)
    out["post_hour"] = ts.dt.hour.astype("Int64")
    out["post_dow"] = ts.dt.day_name()
    out["is_weekend"] = ts.dt.dayofweek.isin([5, 6])
    return out

def add_text_features(frame: pd.DataFrame, text_col: str = "text_content") -> pd.DataFrame:
    out = frame.copy()
    text = out[text_col]
    out["hashtags"] = text.map(extract_hashtags)
    out["hashtag_count"] = out["hashtags"].map(len).astype("Int64")
    out["mentions"] = text.map(extract_mentions)
    out["mention_count"] = out["mentions"].map(len).astype("Int64")
    out["char_length"] = text.map(lambda t: pd.NA if pd.isna(t) else len(str(t))).astype("Int64")
    out["word_count"] = text.map(
        lambda t: pd.NA if pd.isna(t) else len(str(t).split())
    ).astype("Int64")
    out["brand"] = text.map(extract_brand)
    out["product"] = text.map(extract_product)
    out["opener_polarity"] = text.map(score_opener)
    out["verdict_polarity"] = text.map(score_verdict)
    out["sentiment"] = out["verdict_polarity"].map(sentiment_label)
    out["is_contradictory"] = [
        is_contradictory(o, v)
        for o, v in zip(out["opener_polarity"], out["verdict_polarity"])
    ]
    return out

def zscore_by_group(frame: pd.DataFrame, column: str, by: str) -> pd.Series:
    """Within-group z-score. Group-wise so platform scale differences do
    not masquerade as anomalies."""
    grouped = frame.groupby(by, dropna=False)[column]
    mu = grouped.transform("mean")
    sd = grouped.transform("std").replace(0, np.nan)
    return (frame[column] - mu) / sd


def add_anomaly_flags(frame: pd.DataFrame) -> pd.DataFrame:
    out = frame.copy()
    out["engagement_z"] = zscore_by_group(
        out.assign(engagement=out["engagement"].astype("float")),
        "engagement",
        "platform",
    )
    out["is_engagement_outlier"] = out["engagement_z"].abs() > 3
    out["anomaly_flags"] = [
        ";".join(
            flag
            for flag, hit in (
                ("contradictory_sentiment", bool(c)),
                ("engagement_outlier", bool(z)),
                ("shares_exceed_likes", bool(s)),
                ("imputed_likes", bool(i)),
                ("unknown_platform", p == "Unknown"),
                ("missing_text", bool(t)),
            )
            if hit
        )
        for c, z, s, i, p, t in zip(
            out["is_contradictory"],
            out["is_engagement_outlier"].fillna(False),
            out["shares_exceed_likes"],
            out["likes_imputed"],
            out["platform"],
            out["text_content"].isna(),
        )
    ]
    out["is_anomalous"] = out["anomaly_flags"].str.len() > 0
    return out

def build_hashtag_tables(frame: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    pairs = [
        (pid, tag)
        for pid, tags in zip(frame["post_id"], frame["hashtags"])
        for tag in tags
    ]
    bridge = pd.DataFrame(pairs, columns=["post_id", "tag"])
    vocab = (
        bridge["tag"].drop_duplicates().sort_values().reset_index(drop=True).to_frame()
    )
    vocab.insert(0, "hashtag_id", np.arange(1, len(vocab) + 1))
    bridge = bridge.merge(vocab, on="tag")[["post_id", "hashtag_id"]]
    return vocab, bridge.drop_duplicates()
