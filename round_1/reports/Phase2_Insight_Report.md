# Phase 2 — Insight Report

**Data Vortex, Aaruush '26 · Round 1 Phase 2 · Sahil Patel & Suhani Gupta · 15 September 2026**

> Export to PDF for submission. Every query result below must be backed by a
> screenshot showing the **query text and the result grid in the same frame**,
> with the row count visible. The rulebook treats hardcoded outputs as a
> disqualification, so the screenshot is the proof that the number was computed.

---

## 1. Schema design

### 1.1 Why four tables and not one

The Phase 1 output is a denormalised analysis frame. Loading it verbatim would
repeat each of 1,500 users across their 12,000 posts and store hashtags as a
delimited string, forcing `LIKE '%tag%'` scans for every tag question.

| Table | Rows | Grain |
|---|---:|---|
| `dbo.users` | 1,500 | one row per author |
| `dbo.posts` | 12,000 | one row per post, FK to users |
| `dbo.hashtags` | 29 | tag vocabulary |
| `dbo.post_hashtags` | 20,531 | many-to-many bridge |

*[ER diagram here — SSMS → Database Diagrams, or draw it]*

### 1.2 Design decisions

**`engagement` is a `PERSISTED` computed column.** Storing it as a base column
lets it drift out of sync with its inputs; recomputing it in every query costs a
scan. `PERSISTED` gives correctness plus indexability.

**Provenance columns are first class.** `likes_imputed` and `ts_source_format`
are not cleaning debris — they are filters every honest aggregate needs. See §4.4.

**`CHECK` constraints mirror `src/validate.py` exactly.** If a reload ever
reintroduces a negative like count, the `INSERT` fails rather than the analysis
silently changing.

**Indexes are built after the bulk load.** Building them on an empty table then
inserting 12,000 rows makes SQL Server maintain every B-tree per row.

*[Screenshot: `03_constraints_indexes.sql` integrity audit — every row reads 0]*

---

## 2. Trend detection — `sql/04`

### Q4.1 — Daily engagement, 7-day moving average, week-over-week delta

**Logic.** Aggregate to `(platform, day)` first so the window function runs over
~365 rows per platform rather than 12,000. `LAG(7)` compares like-for-like
weekdays, which `LAG(1)` cannot.

*[Screenshot]*

**Result.** _______

**Insight.** _______

### Q4.2 — Monthly trajectory and growth ranking

*[Screenshot]* — **Result.** _______ — **Insight.** _______

### Q4.3 — Hashtag lifecycle

The corpus end date is derived with `MAX()`, never typed as a literal, so the
query stays correct if the data is reloaded.

*[Screenshot]* — **Result.** _______ — **Insight.** _______

### Q4.4 — Posting rhythm ⚠ the filter that matters

Restricted to `ts_source_format <> 'dd_mm_yyyy'`. Those 3,622 rows came from a
**date-only** source, so their time component is `00:00:00` by construction.
Including them manufactures a midnight spike that is an artefact of the ingest
format, not of user behaviour.

*[Screenshot: both versions side by side — with and without the filter]*

**Insight.** _______

### Q4.5 — Cumulative share of voice

*[Screenshot]* — **Result.** _______ — **Insight.** _______

---

## 3. Anomaly discovery — `sql/05`

### Q5.1 — Within-platform z-score

**Logic.** Platforms differ in engagement scale, so a global z-score would flag
an ordinary YouTube post merely because YouTube runs hot. `|z| > 3` is the
conventional three-sigma rule, **chosen before looking at the output**.

*[Screenshot]*

**Result.** Zero posts beyond 3σ.

**Insight.** This negative result is a finding, not a failure. Engagement is
near-uniform within its bounds, consistent with synthetic generation. It also
means an anomaly section built solely on an IQR or z-score sweep of `likes`
returns **nothing** on this dataset. We did not lower the threshold until
something appeared.

### Q5.2 — Contradictory sentiment ⚠ primary anomaly class

A negative opening clause paired with a positive verdict:

> "Bummed out with my new Air Max from Nike! Absolutely loving it."

A single author cannot hold both positions in one sentence. Because the corpus
draws openers and verdicts from closed vocabularies, the lexicon match is
**exact** — no threshold, no model, no false positives.

*[Screenshot: platform breakdown with `WITH ROLLUP`]*
*[Screenshot: brand breakdown]*

**Result.** 329 posts (2.74%).

**Insight.** _______ *(uniform across platforms and brands ⇒ the defect tracks
the corruption process, not user behaviour — corroborating Q5.3)*

### Q5.3 — Was corruption applied row-wise or column-wise?

**Logic.** Cross-tabulate the two damaged columns and compare observed counts
against the product of the marginals. Row-wise damage would make missing
`platform` and missing `text_content` co-occur far more than chance.

*[Screenshot]*

**Result.** _______

**Insight.** _______ *(independence ⇒ a partial write or schema mismatch, not
record loss ⇒ dropping incomplete rows would discard ~30% of the corpus for
nothing)*

### Q5.4 — Shares outrunning likes

Restricted to `likes_imputed = 0`: an imputed like is a group median and cannot
evidence anything about its own row.

*[Screenshot]* — **Result.** _______ — **Insight.** _______

### Q5.5 — Authors deviating from their follower cohort

**Logic.** `NTILE(10)` by follower count, then compare each user against their
**own decile's** mean. Comparing against the global mean would merely rediscover
that large accounts get more engagement.

*[Screenshot]* — **Result.** _______ — **Insight.** _______

---

## 4. Behavioural grouping — `sql/06`

### Q6.1 — Follower quartiles

`NTILE(4)` gives equal-sized cohorts rather than arbitrary cut-offs like "10k+",
which would hardcode an assumption about what counts as large.

*[Screenshot]* — **Insight.** _______

### Q6.2 — Author archetypes

Cut-offs come from `PERCENTILE_CONT(0.5)` computed in the query, so no threshold
is typed by hand and the classification survives a reload.

*[Screenshot]* — **Insight.** _______

### Q6.3 — Geography × language

The corpus contains speakers whose language does not match their country. Treated
as diaspora signal and quantified, **not** "corrected" — forcing language to match
country would destroy a real attribute on the strength of an assumption.

*[Screenshot]* — **Insight.** _______

### Q6.4 — Brand × platform `PIVOT`

*[Screenshot]* — **Insight.** _______

### Q6.5 — Hashtag co-occurrence

Self-join on `post_id` with `hashtag_id >` to count each unordered pair once.

*[Screenshot]* — **Insight.** _______

### Q6.6 — Signup cohort retention

*[Screenshot]* — **Insight.** _______

---

## 5. Correlation analysis — `sql/07`

SQL Server has no built-in `CORR()`, so Pearson's *r* is computed from its
definition using `SUM` aggregates. Every coefficient is calculated from the rows;
nothing is transcribed from the Python EDA.

### Q7.1 — Pairwise correlation across engagement metrics

*[Screenshot]* — **Result.** _______ — **Insight.** _______ *(near-zero ⇒ the
three metrics were generated independently; no organic process links them)*

### Q7.2 — Followers vs engagement, raw and log-log

A real social graph gives a weak raw correlation but a strong log-log one — the
signature of a sublinear power law. Reporting both is how you distinguish "no
relationship" from "non-linear relationship".

*[Screenshot]* — **Result.** raw *r* = _______ , log-log *r* = _______

**Insight.** _______

### Q7.3 — Content shape vs engagement

*[Screenshot]* — **Insight.** _______

### Q7.4 — Sensitivity: what imputation does to a correlation ⚠

The same coefficient computed twice — observed rows only, then all rows including
the 2,323 imputed likes. The gap is the error a team makes by treating imputed
values as observations. **This query is the reason `likes_imputed` was carried
from Phase 1 all the way into the database.**

*[Screenshot]*

| Population | n | Pearson *r* | σ(likes) |
|---|---:|---:|---:|
| Observed only | | | |
| Including imputed | | | |

**Insight.** _______

### Q7.5 — Spearman rank correlation

Comparing Spearman against Pearson separates a genuinely linear relationship from
a merely monotonic one.

*[Screenshot]* — **Insight.** _______

### Q7.6 — Sentiment vs engagement

*[Screenshot]* — **Insight.** _______

---

## 6. Views, procedures, function — `sql/08`

| Object | Purpose |
|---|---|
| `vw_post_enriched` | posts ⋈ users, engagement rate, temporal parts, `has_real_time` |
| `vw_analysis_ready` | observed likes, real text, known platform — the population for any relationship claim |
| `vw_data_quality` | one-query scorecard of corpus state |
| `usp_top_brands_by_platform` | parameterised ranking, `@top` / `@min_posts` / `@observed_only` |
| `usp_anomaly_report` | anomaly counts for an arbitrary date window, derived not cached |
| `fn_platform_percentiles` | inline TVF; the optimiser folds it into the caller rather than running row by row |

*[Screenshot: `SELECT * FROM dbo.vw_data_quality`]*
*[Screenshot: `EXEC dbo.usp_top_brands_by_platform @top = 3`]*
*[Screenshot: `EXEC dbo.usp_anomaly_report`]*

---

## 7. Top findings

| # | Finding | Query | Why it matters |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

---

## 8. Limitations

State plainly. A limitations section that admits real constraints is worth more
than one that lists none.

- 2,323 `likes` values are group medians, not observations. Every relationship
  claim excludes them; volume claims do not.
- 3,622 timestamps carry no time component. Time-of-day analysis covers the
  remaining 8,378 rows only.
- 1,784 posts have no known platform. Retained as `Unknown` rather than inferred
  or dropped.
- 1,779 posts have no text, so text-derived features are null for them.
- The engagement metrics show near-uniform distributions and weak mutual
  correlation, consistent with synthetic generation. Findings about *relationships*
  between metrics should be read with that in mind.

---

**Repository:** `https://github.com/Sahil-Patel180/datavortex26`
**Phase 1 artefacts:** `round_1/data/processed/`, `round_1/docs/cleaning_decisions.md`