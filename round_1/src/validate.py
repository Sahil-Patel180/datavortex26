from __future__ import annotations
import sys
import pandas as pd
from config import (
    CLEAN_POSTS_CSV,
    CLEAN_USERS_CSV,
    COMMENTS_MAX,
    LIKES_MAX,
    SHARES_MAX,
    TS_MAX,
    TS_MIN,
    UNKNOWN_PLATFORM,
    VALID_PLATFORMS,
)

FORBIDDEN_TEXT_PATTERN = r"<[a-z/][^>]{0,40}>|&(?:amp|lt|gt|quot|nbsp|#\d+);|Ã|â€"

class DataContractError(AssertionError):
    """Raised when cleaned data violates the agreed contract."""

def _check(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)

def validate_posts(posts: pd.DataFrame) -> list[str]:
    f: list[str] = []
    _check(posts["post_id"].is_unique, "post_id is not unique", f)
    _check(posts["post_id"].notna().all(), "post_id contains nulls", f)
    _check(posts["user_id"].notna().all(), "user_id contains nulls", f)

    _check(
        posts["platform"].isin(VALID_PLATFORMS + [UNKNOWN_PLATFORM]).all(),
        "platform contains values outside the allowed domain",
        f,
    )

    ts = pd.to_datetime(posts["posted_at"], errors="coerce")
    _check(ts.notna().all(), "posted_at contains unparsed values", f)
    _check(
        ts.between(pd.Timestamp(TS_MIN), pd.Timestamp(TS_MAX)).all(),
        f"posted_at falls outside [{TS_MIN}, {TS_MAX}]",
        f,
    )

    for column, ceiling in (
        ("likes", LIKES_MAX),
        ("shares", SHARES_MAX),
        ("comments", COMMENTS_MAX),
    ):
        values = pd.to_numeric(posts[column], errors="coerce")
        _check(values.notna().all(), f"{column} still contains nulls", f)
        _check(bool((values >= 0).all()), f"{column} contains negative values", f)
        _check(bool((values <= ceiling).all()), f"{column} exceeds ceiling {ceiling}", f)

    text = posts["text_content"].dropna().astype(str)
    _check(
        not text.str.contains(FORBIDDEN_TEXT_PATTERN, regex=True, case=False).any(),
        "text_content still contains markup, HTML entities or mojibake",
        f,
    )
    _check(
        not text.str.contains(r"\s{2,}|^\s|\s$", regex=True).any(),
        "text_content has untrimmed or repeated whitespace",
        f,
    )
    _check(
        not text.str.lower().isin({"null", "none", "nan", "n/a"}).any(),
        "text_content still contains null sentinel strings",
        f,
    )
    return f

def validate_users(users: pd.DataFrame) -> list[str]:
    f: list[str] = []
    _check(users["user_id"].is_unique, "user_id is not unique", f)
    followers = pd.to_numeric(users["follower_count"], errors="coerce")
    _check(followers.notna().all(), "follower_count contains nulls", f)
    _check(bool((followers >= 0).all()), "follower_count contains negatives", f)
    created = pd.to_datetime(users["account_created"], errors="coerce")
    _check(created.notna().all(), "account_created contains unparsed values", f)
    return f

def validate_referential(posts: pd.DataFrame, users: pd.DataFrame) -> list[str]:
    f: list[str] = []
    orphans = ~posts["user_id"].isin(users["user_id"])
    _check(not orphans.any(), f"{int(orphans.sum())} posts reference unknown user_id", f)

    merged = posts.merge(
        users[["user_id", "account_created"]], on="user_id", how="left"
    )
    before = pd.to_datetime(merged["posted_at"]) < pd.to_datetime(
        merged["account_created"]
    )
    _check(
        not before.any(),
        f"{int(before.sum())} posts predate their author's account creation",
        f,
    )
    return f

def validate_all(posts: pd.DataFrame, users: pd.DataFrame) -> list[str]:
    return validate_posts(posts) + validate_users(users) + validate_referential(posts, users)

def main() -> int:
    posts = pd.read_csv(CLEAN_POSTS_CSV)
    users = pd.read_csv(CLEAN_USERS_CSV)
    failures = validate_all(posts, users)
    if failures:
        print("DATA CONTRACT FAILED")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"DATA CONTRACT PASSED  posts={len(posts)}  users={len(users)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
