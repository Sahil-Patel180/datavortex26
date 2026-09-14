# Data Dictionary

Schema of everything in `data/processed/`. Types are given as pandas dtype /
T-SQL type, since the same tables are loaded into SQL Server for Phase 2.

---

## `posts_clean.csv` — 12,000 rows × 32 columns

Grain: one row per post. Primary key: `post_id`.

### Identity & source

| Column | Type | Null? | Description |
|---|---|---|---|
| `post_id` | string / `VARCHAR(20)` | no | Primary key. 360 duplicates removed from raw. |
| `user_id` | string / `VARCHAR(20)` | no | FK → `users_clean.user_id`. Zero orphans. |
| `platform` | string / `VARCHAR(20)` | no | One of Facebook, Instagram, Reddit, Twitter, YouTube, **Unknown**. `Unknown` = missing in source, never inferred. |
| `ts_source_format` | string / `VARCHAR(16)` | no | Provenance of the raw timestamp: `iso8601`, `unix_seconds`, `dd_mm_yyyy`. Retained as an ingest-shard fingerprint. |

### Content

| Column | Type | Null? | Description |
|---|---|---|---|
| `text_content` | string / `NVARCHAR(500)` | **yes** (1,779) | Cleaned post body. Mojibake repaired, entities unescaped, markup stripped, whitespace squashed. Guaranteed free of `<tag>`, `&entity;`, `Ã`, double spaces, and null sentinels. |
| `char_length` | Int64 / `INT` | yes | Characters after cleaning. |
| `word_count` | Int64 / `INT` | yes | Whitespace-delimited tokens. |
| `hashtag_count` | Int64 / `INT` | yes | Distinct hashtags, case-insensitive. 0–3 observed. |
| `mention_count` | Int64 / `INT` | yes | Distinct `@handles`. 15 distinct handles corpus-wide. |
| `brand` | string / `VARCHAR(30)` | yes | Resolved via the product catalogue first, bare brand mention second. 10 brands. |
| `product` | string / `VARCHAR(40)` | yes | Product model named in the post. |

### Time

| Column | Type | Null? | Description |
|---|---|---|---|
| `posted_at` | datetime / `DATETIME2(0)` | no | Unified timestamp, UTC. Range 2024-05-01 → 2025-04-30. |
| `post_date` | date / `DATE` | no | Date part. |
| `post_month` | string / `CHAR(7)` | no | `YYYY-MM`. |
| `post_hour` | Int64 / `TINYINT` | no | 0–23. Always 0 for `dd_mm_yyyy` rows — date-only source, **not** a midnight posting spike. Filter on `ts_source_format` for hour-of-day analysis. |
| `post_dow` | string / `VARCHAR(9)` | no | Day name. |
| `is_weekend` | bool / `BIT` | no | Saturday or Sunday. |

### Engagement

| Column | Type | Null? | Description |
|---|---|---|---|
| `likes` | Int64 / `INT` | no | 0–5,000. 2,323 values imputed — **check `likes_imputed`**. |
| `likes_imputed` | bool / `BIT` | no | 1 = value is a group median, not observed. Exclude these rows from correlation and variance work. |
| `shares` | Int64 / `INT` | no | 0–2,000. Fully observed, untouched. |
| `comments` | Int64 / `INT` | no | 0–1,000. Fully observed, untouched. |
| `engagement` | Int64 / `INT` | no | `likes + shares + comments`. Computed column in SQL. |
| `engagement_rate` | Float64 / `FLOAT` | yes | `engagement / follower_count`. Null when followers = 0. |

### Sentiment

| Column | Type | Null? | Description |
|---|---|---|---|
| `opener_polarity` | Int64 / `SMALLINT` | yes | −1 / 0 / +1 from the leading emotional clause. Null when the template used no opener. |
| `verdict_polarity` | Int64 / `SMALLINT` | yes | −1 / 0 / +1 from the closing verdict clause. |
| `sentiment` | string / `VARCHAR(10)` | yes | `positive` / `neutral` / `negative`, anchored on the verdict. |
| `is_contradictory` | bool / `BIT` | no | Opener and verdict carry opposite non-zero polarity. 329 rows. |

### Anomaly

| Column | Type | Null? | Description |
|---|---|---|---|
| `engagement_z` | Float64 / `FLOAT` | yes | Z-score of `engagement` within `platform`. |
| `is_engagement_outlier` | bool / `BIT` | yes | \|z\| > 3. Zero rows — reported as a negative result. |
| `shares_exceed_likes` | bool / `BIT` | no | Soft flag; unusual on real platforms. |
| `anomaly_flags` | string / `VARCHAR(200)` | no | Semicolon-joined flag names; empty when clean. |
| `is_anomalous` | bool / `BIT` | no | Any flag set. |

---

## `users_clean.csv` — 1,500 rows × 5 columns

Grain: one row per user. Primary key: `user_id`.

| Column | Type | Null? | Description |
|---|---|---|---|
| `user_id` | string / `VARCHAR(20)` | no | Primary key. Unique in source. |
| `city` | string / `NVARCHAR(60)` | yes | Split from the composite `location`. |
| `country` | string / `NVARCHAR(60)` | yes | Split from the composite `location`. |
| `language` | string / `CHAR(2)` | yes | ISO-639-1, lower-cased. 10 values: ar, de, en, es, fr, hi, ja, pt, ru, zh. |
| `account_created` | date / `DATE` | no | All of calendar 2023. Uniform `dd-mm-yyyy` in source. |
| `follower_count` | Int64 / `INT` | no | No nulls, no negatives in source. |

**Note:** `language` and `country` are independent in this corpus — e.g. `ja` speakers in Berlin. Treated as legitimate diaspora signal, not corruption; quantified in the EDA rather than "fixed".

---

## `hashtags.csv` — 29 rows

| Column | Type | Description |
|---|---|---|
| `hashtag_id` | Int64 / `INT IDENTITY` | Surrogate key. |
| `tag` | string / `VARCHAR(50)` | Lower-cased tag without `#`. Unique. 29 tags after the D5b suffix fix; 56 before it (27 were mojibake ghosts). |

## `post_hashtags.csv` — 20,531 rows

Bridge table resolving the many-to-many between posts and hashtags. Exists
so hashtag analysis in Phase 2 is a join rather than a `LIKE '%...%'` scan.

| Column | Type | Description |
|---|---|---|
| `post_id` | string / `VARCHAR(20)` | FK → `posts.post_id` |
| `hashtag_id` | Int64 / `INT` | FK → `hashtags.hashtag_id` |

Composite primary key `(post_id, hashtag_id)`.

## `cleaning_audit.csv` — 24 rows

Machine-generated transformation log emitted by `src/run_pipeline.py`.
Columns: `step`, `issue`, `rows_affected`, `action`. This file is the
evidence behind every count quoted in `cleaning_decisions.md`.
