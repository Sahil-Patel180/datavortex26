from __future__ import annotations
import html
import re
import unicodedata
import numpy as np
import pandas as pd
from config import NULL_SENTINELS, UNKNOWN_PLATFORM, VALID_PLATFORMS

def load_raw(path) -> pd.DataFrame:
    return pd.read_csv(path, dtype=str, keep_default_na=False, encoding="utf-8")

def is_sentinel(value) -> bool:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return True
    return str(value).strip().lower() in NULL_SENTINELS

def normalise_nulls(series: pd.Series) -> pd.Series:
    return series.map(lambda v: pd.NA if is_sentinel(v) else v)

_TAG_RE = re.compile(r"<[^>]{1,40}>")
_WS_RE = re.compile(r"\s+")
_MOJIBAKE_MARKERS = ("Ã", "â€", "Â")

_NOISE_SUFFIX_RE = re.compile(r"(?:<div>|</div>|<br\s*/?>|&amp;|Ã©|\s)+$")

def fix_mojibake(text: str) -> str:
    if not any(m in text for m in _MOJIBAKE_MARKERS):
        return text
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text

def strip_noise_suffix(text: str) -> str:
    return _NOISE_SUFFIX_RE.sub("", text)

def has_noise_suffix(text: str) -> bool:
    return bool(_NOISE_SUFFIX_RE.search(str(text)))

def clean_text(value) -> object:
    if is_sentinel(value):
        return pd.NA
    text = str(value)
    text = strip_noise_suffix(text)
    text = fix_mojibake(text)
    text = html.unescape(text)
    text = _TAG_RE.sub(" ", text)
    text = unicodedata.normalize("NFKC", text)
    text = _WS_RE.sub(" ", text).strip()
    if is_sentinel(text):
        return pd.NA
    return text

_UNIX10_RE = re.compile(r"^\d{10}$")
_UNIX13_RE = re.compile(r"^\d{13}$")
_DMY_RE = re.compile(r"^\d{2}-\d{2}-\d{4}$")


def detect_ts_format(value) -> str:
    if is_sentinel(value):
        return "missing"
    s = str(value).strip()
    if _UNIX10_RE.match(s):
        return "unix_seconds"
    if _UNIX13_RE.match(s):
        return "unix_millis"
    if _DMY_RE.match(s):
        return "dd_mm_yyyy"
    if "T" in s:
        return "iso8601"
    return "unparsed"


def parse_timestamp(value):
    if is_sentinel(value):
        return pd.NaT
    s = str(value).strip()
    if _UNIX10_RE.match(s):
        return pd.to_datetime(int(s), unit="s")
    if _UNIX13_RE.match(s):
        return pd.to_datetime(int(s), unit="ms")
    if _DMY_RE.match(s):
        return pd.to_datetime(s, format="%d-%m-%Y")
    return pd.to_datetime(s, errors="coerce")


def assert_dayfirst(series: pd.Series) -> int:
    hits = series.astype(str).str.extract(r"^(\d{2})-(\d{2})-\d{4}$")
    return int(pd.to_numeric(hits[0], errors="coerce").gt(12).sum())

def to_int_metric(series: pd.Series) -> pd.Series:
    return pd.to_numeric(normalise_nulls(series), errors="coerce").astype("Int64")


def flag_impossible(series: pd.Series, upper: int) -> pd.Series:
    return series.notna() & ((series < 0) | (series > upper))


def null_impossible(series: pd.Series, upper: int) -> pd.Series:
    return series.mask(flag_impossible(series, upper))


def impute_by_group(
    frame: pd.DataFrame, column: str, by: list[str]
) -> tuple[pd.Series, pd.Series]:
    was_imputed = frame[column].isna()
    values = frame[column].astype("Float64")
    group_median = frame.groupby(by, dropna=False)[column].transform("median").astype("Float64")
    filled = values.fillna(group_median)
    filled = filled.fillna(values.median())  # groups that are entirely NA
    return filled.round().astype("Int64"), was_imputed

_PLATFORM_CANON = {p.lower(): p for p in VALID_PLATFORMS}
_PLATFORM_CANON.update({"x": "Twitter", "x (twitter)": "Twitter", "fb": "Facebook",
                        "ig": "Instagram", "yt": "YouTube"})


def canon_platform(value) -> str:
    if is_sentinel(value):
        return UNKNOWN_PLATFORM
    return _PLATFORM_CANON.get(str(value).strip().lower(), UNKNOWN_PLATFORM)


def split_location(series: pd.Series) -> pd.DataFrame:
    parts = series.fillna("").str.split(",", n=1, expand=True)
    city = parts[0].str.strip().replace("", pd.NA)
    country = (
        parts[1].str.strip().replace("", pd.NA)
        if parts.shape[1] > 1
        else pd.Series(pd.NA, index=series.index)
    )
    return pd.DataFrame({"city": city, "country": country})


def canon_language(series: pd.Series) -> pd.Series:
    out = normalise_nulls(series).astype("string").str.strip().str.lower()
    return out.mask(out.str.len() != 2)

def drop_duplicate_posts(frame: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    dupe_mask = frame.duplicated(subset=["post_id"], keep="first")
    return frame.loc[~dupe_mask].copy(), frame.loc[dupe_mask].copy()
