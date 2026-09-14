# Cleaning Decisions — Dataset 01

Every transformation applied to the corrupted corpus, the rule used, the
alternative that was rejected, and why. Counts are produced by
`src/run_pipeline.py` and written to `data/processed/cleaning_audit.csv`;
nothing in this table is hand-entered.

Input: 12,360 post rows × 8 columns, 1,500 user rows × 5 columns.
Output: 12,000 post rows × 32 columns, 1,500 user rows × 5 columns.

---

## D0 — Load without implicit coercion

| | |
|---|---|
| **Issue** | `pandas.read_csv` defaults fold the literal token `NULL` into `NaN` |
| **Rows** | 1,814 (`likes`) + 1,784 (`platform`) + 1,711 (`text_content`) |
| **Rule** | `read_csv(..., dtype=str, keep_default_na=False, encoding="utf-8")` |
| **Rejected** | Default load |
| **Why** | The default silently merges two *distinct* missing-value encodings. Losing that distinction destroys evidence about how the corruption was applied (see D1). Read raw, decide explicitly. |

---

## D1 — Dual missing-value encoding

| | |
|---|---|
| **Issue** | Missingness is encoded **two ways**: empty string and the literal string `NULL` |
| **Rows** | `platform` 1,177 `""` + 607 `"NULL"`; `text_content` 1,154 + 557; `likes` 1,199 + 615 |
| **Rule** | `NULL_SENTINELS` set in `config.py`; case-insensitive, whitespace-stripped, unified to `pd.NA` |
| **Rejected** | Handling only `""`, or only `NULL` |
| **Why** | Either alone leaves ~40% of the nulls undetected. `shares` and `comments` have **zero** nulls in either encoding — the corruption was applied to a targeted column subset, not uniformly. That asymmetry is a finding, reported in the EDA, not a nuisance. |

**Note:** `NULLIFY`-style false positives are avoided because matching is on the *whole stripped cell*, never a substring.

---

## D2 — Duplicate records

| | |
|---|---|
| **Issue** | 360 duplicated `post_id` values |
| **Rows** | 360 dropped (12,360 → 12,000) |
| **Rule** | `drop_duplicates(subset=["post_id"], keep="first")` |
| **Rejected** | (a) keep all; (b) de-duplicate on `text_content` |
| **Why** | Verified first that all 360 are **full-row** identical, so `keep="first"` discards no information and needs no merge rule. De-duplicating on text would be wrong: 2,133 posts share wording because the corpus is template-generated. Identical text under different `post_id` values is expected behaviour, not corruption. `post_id` is the only defensible key. |

---

## D3 — Text: mojibake

| | |
|---|---|
| **Issue** | `Ã©` appearing where `é` belongs — UTF-8 bytes decoded as Latin-1 upstream |
| **Rows** | 306 |
| **Rule** | `text.encode("latin-1").decode("utf-8")`, applied **only** when a marker (`Ã`, `â€`, `Â`) is present |
| **Rejected** | Unconditional round-trip; `unidecode`; regex character substitution |
| **Why** | An unconditional round-trip corrupts text that is already correct and raises on any codepoint outside Latin-1. `unidecode` would strip the accent entirely — that is data loss, not repair. A substitution table only covers the sequences you happened to notice. |

---

## D4 — Text: HTML entities and markup

| | |
|---|---|
| **Issue** | `&amp;`, `&lt;` entities (328 rows); `<br>`, `<div>` tags (646 rows) |
| **Rule** | `html.unescape()` → then strip `<[^>]{1,40}>` → then NFKC normalise |
| **Rejected** | Tag strip before unescape; BeautifulSoup |
| **Why** | Order is load-bearing. Unescaping after stripping can *resurrect* markup from `&lt;div&gt;`. The `{1,40}` bound prevents a stray `<` in prose from eating the rest of the sentence. BeautifulSoup is a heavy dependency for what is a fixed, tiny tag vocabulary. |

---

## D5 — Text: whitespace

| | |
|---|---|
| **Issue** | 988 rows with repeated internal whitespace, 329 with leading/trailing space |
| **Rule** | `re.sub(r"\s+", " ", text).strip()` |
| **Rejected** | `.strip()` only |
| **Why** | Internal doubling is left behind by the tag strip in D4 and by the generator itself. Un-squashed whitespace breaks exact-match grouping and inflates `char_length`. |

---

## D5b — Injected terminal noise token ⚠ subtle, high-impact

| | |
|---|---|
| **Issue** | A junk token appended to the **end** of a cell |
| **Rows** | 1,609 |
| **Rule** | Strip `(?:<div>|</div>|<br\s*/?>|&amp;|Ã©|\s)+$` **before** any other text repair |
| **Rejected** | Treating each token with its own generic handler (tag strip, unescape, mojibake repair) |
| **Why** | Census of the raw corpus: `&amp;` 341, `<div>` 338, `\n\n` 337, `<br>` 325, `Ã©` 316 — five tokens at roughly 330 rows each, a uniform draw from a closed set, and **every single occurrence is terminal**. They are one corruption mechanism, not five, and naming it as one is what makes the next point visible. |

**Why order matters here.** `Ã©` is the trap. A generic mojibake pass "repairs"
it to `é` and welds it onto the last word — `#Travel` silently becomes
`#Travelé`, `#Affordable` becomes `#Affordableé`. Those phantom tags then
enter the hashtag vocabulary as distinct entries and every hashtag
aggregate in Phase 2 is quietly wrong.

Measured effect of stripping the suffix first: the hashtag vocabulary
collapses from **56 tags to 29**. Twenty-seven of the original 56 were
mojibake ghosts of tags that already existed. This single ordering decision
is the difference between a correct hashtag analysis and a plausible-looking
broken one.

Genuine in-sentence `Ã©` is still repaired normally by D3 — only the
terminal marker is removed.

---

## D6 — Text: sentinels disguised by noise ⚠ highest-value rule

| | |
|---|---|
| **Issue** | Cells such as `NULL<div>`, `NULL&amp;`, `NULLÃ©`, `NULL\n\n` |
| **Rows** | ~75 that a single-pass check misses |
| **Rule** | Run the sentinel check **twice** — once on the raw cell, again after D3–D5 |
| **Rejected** | Single sentinel pass before cleaning |
| **Why** | These cells are missing values wearing a costume. A pre-clean check sees `NULL<div>` as content; a post-clean check sees `NULL` and correctly nulls it. Skipping the second pass leaves ~75 fake "posts" that pollute every text metric downstream. Final `text_content` null count: 1,779. |

---

## D7 — Timestamps: three formats in one column

| | |
|---|---|
| **Issue** | ISO-8601 (4,950), Unix seconds (3,788), `dd-mm-yyyy` (3,622) |
| **Rule** | Regex-dispatch each row to the right parser → single `datetime2(0)` |
| **Rejected** | `pd.to_datetime(..., errors="coerce")` in one shot |
| **Why** | A blanket call silently coerces the 10-digit epoch strings to `NaT` or misreads them as years, quietly destroying 31% of the temporal axis. |

**`ts_source_format` is retained as a column.** The format is a provenance fingerprint of the upstream ingest shard, and it is used as a stratifier during imputation (D9) and as an EDA hypothesis.

---

## D8 — Timestamps: day-first vs month-first

| | |
|---|---|
| **Issue** | `25-09-2024` — is `25` the day or the month? |
| **Rule** | Parse as `%d-%m-%Y` |
| **Rejected** | `dayfirst=False`; `dayfirst=True` without checking |
| **Why** | **Evidenced, not assumed.** 2,113 rows have a first component greater than 12, which is only possible if that component is the day. `clean.assert_dayfirst()` recomputes this at runtime and the pipeline **raises** if the count ever drops to zero. Parsed range: 2024-05-01 → 2025-04-30, a clean 12-month window, which corroborates the reading. |

---

## D9 — Negative `likes`

| | |
|---|---|
| **Issue** | 509 rows with `likes < 0` (minimum −4,987) |
| **Rule** | Set to `NA`, then impute; record `likes_imputed = 1` |
| **Rejected** | (a) `abs()`; (b) clip to 0; (c) drop the rows |
| **Why** | A like is a **count**; counts have a floor of zero, so these are corruption, not outliers. `abs()` assumes a sign-bit flip we cannot evidence and would inject a fabricated magnitude of up to 4,987 — the rulebook prohibits fabricating data. Clipping to 0 invents a different lie and distorts the distribution's left tail. Dropping loses 509 otherwise-valid rows including their `shares`, `comments` and text. Nulling then flagging is the only option that neither invents nor discards. |

`shares` and `comments` contain no negatives and no values above their observed ceilings — left untouched.

---

## D10 — Imputing `likes`

| | |
|---|---|
| **Issue** | 2,323 nulls after D1 + D9 (1,814 original + 509 demoted) |
| **Rule** | Median within `platform × ts_source_format`; `likes_imputed` flag persisted to CSV **and to SQL** |
| **Rejected** | (a) global median; (b) mean; (c) leave null; (d) regression/KNN imputation |
| **Why** | Engagement scale differs by platform, so a global median flattens exactly the between-platform signal Phase 2 must measure. Median over mean because the demoted negatives left a skewed residual. Leaving nulls would silently drop 19% of rows from every SQL aggregate. Model-based imputation manufactures correlation structure that was never observed — fatal when the next task is correlation analysis. |

**The flag is the point.** Every correlation and variance estimate in Phase 2 filters `likes_imputed = 0`; aggregates that tolerate imputation use the full set. Both are reported side by side so the reader can see the sensitivity.

---

## D11 — Missing `platform`

| | |
|---|---|
| **Issue** | 1,784 rows with no platform |
| **Rule** | Map to the explicit category `'Unknown'` |
| **Rejected** | (a) infer from the user's other posts; (b) infer from text style; (c) drop |
| **Why** | Inference here is **fabrication** — there is no deterministic mapping from author or wording to platform in this corpus, so any guess manufactures 1,784 data points. An explicit `Unknown` category keeps the rows analysable *and* keeps the missingness itself measurable: the EDA tests whether `platform`-missingness is independent of `likes`-missingness, which speaks to whether corruption was applied row-wise or column-wise. |

---

## D12 — Users table

| | |
|---|---|
| **Issue** | `location` is a composite `"City, Country"` string |
| **Rule** | Split into `city` / `country`; lower-case `language` to ISO-639-1 |
| **Rejected** | Keep the composite string |
| **Why** | Composite columns violate 1NF and make country-level aggregation a string operation in SQL. `user_id` is unique, `follower_count` has no nulls or negatives, `account_created` is uniformly `dd-mm-yyyy` — the users table is clean, and saying so explicitly matters as much as fixing what is broken. |

---

## D13 — Referential and temporal integrity

Checked, not assumed:

- **0** posts reference an unknown `user_id` → foreign key is sound.
- **0** posts predate their author's `account_created` → no temporal violations.
- **0** timestamps fall outside the 2024-05-01 → 2025-04-30 window.

All three are enforced as hard assertions in `src/validate.py`, so a regression fails CI rather than reaching the report.

---

## D14 — Anomalies: flagged, never deleted

Anomaly detection is separate from cleaning. Cleaning fixes what is provably
wrong; anomaly detection *labels* what is suspicious and leaves the analyst
to judge. Nothing in this section removes a row.

| Class | Rows | Detection |
|---|---:|---|
| Contradictory sentiment | 329 | Opener polarity × verdict polarity < 0 |
| Sign-flipped `likes` | 509 | `likes < 0` (repaired in D9, still flagged) |
| Duplicate `post_id` | 360 | Removed in D2, retained in the audit log |
| Unknown platform | 1,784 | Sentinel in D1 |
| Missing text | 1,779 | Sentinel in D1 + D6 |
| `shares > likes` | — | Soft flag; rare on real platforms |
| Engagement \|z\| > 3 within platform | 0 | Group-wise z-score |

**On the contradiction class.** Posts like

> "Bummed out with my new Air Max from Nike! Absolutely loving it."

pair a negative opener with a positive verdict. A single author cannot hold
both positions in one sentence, so these are injected noise rather than
natural variance. Because the corpus is template-generated from closed
opener and verdict vocabularies, a lexicon lookup is **exact** here — no
threshold, no model, no false positives. This is the anomaly class a generic
IQR-on-`likes` sweep cannot see.

**On the zero z-score outliers.** Group-wise z-scoring finds nothing beyond
3σ. That is itself informative: the engagement metrics are near-uniform
within their bounds, consistent with synthetic generation. Reporting a
negative result honestly is better than lowering the threshold until
something appears.

---

## Assumptions register

Stated explicitly, as required by the rulebook:

1. `post_id` is the primary key and is intended to be unique.
2. Engagement metrics are non-negative integers; their observed maxima
   (5,000 / 2,000 / 1,000) are generator bounds, so values beyond them
   would be corruption. None were found above the ceiling.
3. The `dd-mm-yyyy` rows are day-first — evidenced in D8, re-asserted at
   runtime.
4. Unix timestamps are in **seconds** (10 digits) and UTC. No 13-digit
   millisecond values were observed; the parser handles them anyway.
5. Text duplication is a property of the generator, not corruption.
6. The brand/product catalogue in `config.py` was **derived from the corpus**
   by extracting every `"<product> from <brand>"` pair — not typed from
   outside knowledge. All 10 brands map to a disjoint product set with zero
   cross-brand collisions.
7. Sentiment is anchored on the **verdict** clause, because that is where
   the template places the author's actual judgement.
