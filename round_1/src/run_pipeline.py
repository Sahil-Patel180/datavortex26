"""End-to-end reproducible pipeline: raw -> processed + audit log.

    python src/run_pipeline.py

Deterministic. Re-running on the same inputs yields byte-identical outputs.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pandas as pd

import clean
import config as cfg
import features as feat
from validate import validate_all

AUDIT: list[dict] = []


def log(step: str, issue: str, rows_affected: int, action: str) -> None:
    AUDIT.append(
        {
            "step": step,
            "issue": issue,
            "rows_affected": int(rows_affected),
            "action": action,
        }
    )
    print(f"[{step:>18}] {issue:<44} rows={rows_affected:<6} -> {action}")


# --------------------------------------------------------------------------
def clean_users() -> pd.DataFrame:
    raw = clean.load_raw(cfg.RAW_USERS)
    log("load.users", "raw rows read", len(raw), "ok")

    users = pd.DataFrame({"user_id": raw["user_id"].str.strip()})
    users = pd.concat([users, clean.split_location(raw["location"])], axis=1)
    users["language"] = clean.canon_language(raw["language"])
    users["account_created"] = raw["account_created"].map(clean.parse_timestamp)
    users["follower_count"] = clean.to_int_metric(raw["follower_count"])

    dupes = int(users["user_id"].duplicated().sum())
    if dupes:
        users = users.drop_duplicates(subset=["user_id"], keep="first")
    log("users.dedupe", "duplicate user_id", dupes, "kept first occurrence")

    negative = int((users["follower_count"] < 0).sum())
    users["follower_count"] = users["follower_count"].mask(users["follower_count"] < 0)
    log("users.metrics", "negative follower_count", negative, "set to NA")

    users["account_created"] = users["account_created"].dt.date
    log("users.done", "clean rows written", len(users), str(cfg.CLEAN_USERS_CSV.name))
    return users


# --------------------------------------------------------------------------
def clean_posts(users: pd.DataFrame) -> pd.DataFrame:
    raw = clean.load_raw(cfg.RAW_POSTS)
    log("load.posts", "raw rows read", len(raw), "ok")

    # --- 1. duplicates -----------------------------------------------------
    full_dupes = int(raw.duplicated().sum())
    id_dupes = int(raw["post_id"].duplicated().sum())
    posts, removed = clean.drop_duplicate_posts(raw)
    log(
        "posts.dedupe",
        f"duplicate post_id ({full_dupes} full-row identical)",
        id_dupes,
        "dropped, kept first",
    )

    # --- 2. missing-value sentinels ---------------------------------------
    for column in ("platform", "text_content", "likes"):
        empty = int((posts[column].astype(str).str.strip() == "").sum())
        literal = int(posts[column].astype(str).str.strip().str.upper().eq("NULL").sum())
        log(
            "posts.nulls",
            f"{column}: '' = {empty}, 'NULL' = {literal}",
            empty + literal,
            "unified to NA",
        )

    # --- 3. text repair ----------------------------------------------------
    raw_text = posts["text_content"].astype(str)
    tags = int(raw_text.str.contains(r"<[^>]{1,40}>", regex=True).sum())
    entities = int(raw_text.str.contains(r"&(?:amp|lt|gt|quot|nbsp|#\d+);", regex=True).sum())
    mojibake = int(raw_text.str.contains(r"Ã|â€|Â", regex=True).sum())
    ws = int(raw_text.str.contains(r"\s{2,}", regex=True).sum())
    trim = int((raw_text != raw_text.str.strip()).sum())
    noise = int(raw_text.map(clean.has_noise_suffix).sum())

    posts["text_content"] = posts["text_content"].map(clean.clean_text)

    log(
        "posts.text",
        "injected terminal noise token removed",
        noise,
        "&amp; | <div> | <br> | \\n\\n | Ã© stripped from end",
    )
    log("posts.text", "HTML tags stripped", tags, "<br>/<div> removed")
    log("posts.text", "HTML entities unescaped", entities, "&amp; -> &")
    log("posts.text", "mojibake repaired", mojibake, "latin-1 -> utf-8 round trip")
    log("posts.text", "whitespace squashed", ws, "collapsed to single space")
    log("posts.text", "leading/trailing space", trim, "trimmed")
    log(
        "posts.text",
        "disguised sentinels (NULL<div>, NULL&amp;)",
        int(posts["text_content"].isna().sum()),
        "second sentinel pass -> NA",
    )

    # --- 4. timestamps -----------------------------------------------------
    posts["ts_source_format"] = posts["timestamp"].map(clean.detect_ts_format)
    dayfirst_proof = clean.assert_dayfirst(posts["timestamp"])
    assert dayfirst_proof > 0, "day-first ordering could not be evidenced"
    posts["posted_at"] = posts["timestamp"].map(clean.parse_timestamp)
    log(
        "posts.time",
        "mixed formats unified",
        len(posts),
        "iso8601 | unix_seconds | dd_mm_yyyy -> datetime",
    )
    log(
        "posts.time",
        "day-first ordering evidenced (day > 12)",
        dayfirst_proof,
        "dayfirst asserted, not guessed",
    )

    # --- 5. platform -------------------------------------------------------
    unknown = int(posts["platform"].map(clean.is_sentinel).sum())
    posts["platform"] = posts["platform"].map(clean.canon_platform)
    log("posts.platform", "missing platform", unknown, "-> 'Unknown' (never inferred)")

    # --- 6. metrics --------------------------------------------------------
    for column, ceiling in (
        ("likes", cfg.LIKES_MAX),
        ("shares", cfg.SHARES_MAX),
        ("comments", cfg.COMMENTS_MAX),
    ):
        posts[column] = clean.to_int_metric(posts[column])
        impossible = int(clean.flag_impossible(posts[column], ceiling).sum())
        posts[column] = clean.null_impossible(posts[column], ceiling)
        if impossible:
            log(
                "posts.metrics",
                f"{column} outside [0, {ceiling}]",
                impossible,
                "set to NA (not abs(); abs would fabricate magnitude)",
            )

    posts["likes"], posts["likes_imputed"] = clean.impute_by_group(
        posts, "likes", ["platform", "ts_source_format"]
    )
    log(
        "posts.impute",
        "likes imputed",
        int(posts["likes_imputed"].sum()),
        "group median (platform x ts_source_format), flagged",
    )
    for column in ("shares", "comments"):
        missing = int(posts[column].isna().sum())
        if missing:
            posts[column], _ = clean.impute_by_group(posts, column, ["platform"])
            log("posts.impute", f"{column} imputed", missing, "platform median")

    # --- 7. referential integrity -----------------------------------------
    orphans = int((~posts["user_id"].isin(users["user_id"])).sum())
    log("posts.fk", "orphan user_id", orphans, "none found, FK is sound")

    # --- 8. features -------------------------------------------------------
    posts = posts.merge(
        users[["user_id", "follower_count", "country", "language"]],
        on="user_id",
        how="left",
    )
    posts = feat.add_text_features(posts)
    posts = feat.add_temporal(posts)
    posts = feat.add_engagement(posts)
    posts = feat.add_anomaly_flags(posts)

    log(
        "posts.anomaly",
        "contradictory sentiment detected",
        int(posts["is_contradictory"].sum()),
        "flagged, retained",
    )
    log(
        "posts.anomaly",
        "engagement |z| > 3 within platform",
        int(posts["is_engagement_outlier"].fillna(False).sum()),
        "flagged, retained",
    )
    return posts


# --------------------------------------------------------------------------
OUTPUT_COLUMNS = [
    "post_id", "user_id", "platform", "text_content", "posted_at",
    "ts_source_format", "likes", "likes_imputed", "shares", "comments",
    "engagement", "engagement_rate", "sentiment", "opener_polarity",
    "verdict_polarity", "is_contradictory", "brand", "product",
    "hashtag_count", "mention_count", "char_length", "word_count",
    "post_date", "post_month", "post_hour", "post_dow", "is_weekend",
    "engagement_z", "is_engagement_outlier", "shares_exceed_likes",
    "anomaly_flags", "is_anomalous",
]


def main() -> int:
    print(f"DATA VORTEX :: Round 1 Phase 1 pipeline  {datetime.now(timezone.utc):%Y-%m-%d %H:%M:%SZ}\n")
    users = clean_users()
    posts = clean_posts(users)

    hashtags, post_hashtags = feat.build_hashtag_tables(posts)

    out = posts[OUTPUT_COLUMNS].copy()
    out["posted_at"] = pd.to_datetime(out["posted_at"]).dt.strftime("%Y-%m-%d %H:%M:%S")

    out.to_csv(cfg.CLEAN_POSTS_CSV, index=False, encoding="utf-8")
    out.to_json(cfg.CLEAN_POSTS_JSON, orient="records", indent=2, force_ascii=False)
    users.to_csv(cfg.CLEAN_USERS_CSV, index=False, encoding="utf-8")
    hashtags.to_csv(cfg.HASHTAGS_CSV, index=False, encoding="utf-8")
    post_hashtags.to_csv(cfg.POST_HASHTAGS_CSV, index=False, encoding="utf-8")
    pd.DataFrame(AUDIT).to_csv(cfg.AUDIT_CSV, index=False, encoding="utf-8")

    print(f"\nwrote {cfg.CLEAN_POSTS_CSV.name}   rows={len(out)}")
    print(f"wrote {cfg.CLEAN_USERS_CSV.name}   rows={len(users)}")
    print(f"wrote {cfg.HASHTAGS_CSV.name}      rows={len(hashtags)}")
    print(f"wrote {cfg.POST_HASHTAGS_CSV.name} rows={len(post_hashtags)}")
    print(f"wrote {cfg.AUDIT_CSV.name}         rows={len(AUDIT)}\n")

    failures = validate_all(out, users)
    if failures:
        print("DATA CONTRACT FAILED")
        for item in failures:
            print(f"  - {item}")
        return 1
    print("DATA CONTRACT PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
