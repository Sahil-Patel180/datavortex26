# Data Vortex — Aaruush '26

Rebuilding the Social Engine. Round 1 submission: dataset recovery, intake
restoration, and the SQL analytical core.

![data-quality](https://github.com/USER/datavortex26/actions/workflows/ci.yml/badge.svg)

> Replace `USER` in the badge URL with the GitHub account or org this repo
> lives under.

---

## What happened

The Social Engine's data intake pipeline collapsed. The corrupted dataset was
not handed out — it had to be recovered from the failing system itself at
`https://datavortex-social-engine.vercel.app/`. The full solve path is in
[`round_1/docs/site_recon.md`](round_1/docs/site_recon.md); the short version is
that the system log names `node_07` as the last surviving node, the recovery
shell accepts `connect node_07`, and Archive Node 07 serves the two CSVs.

From there: 12,360 deliberately corrupted post records and 1,500 user records,
restored to a 12,000-row analysis-ready dataset and loaded into SQL Server.

---

## Results

| | |
|---|---|
| Raw posts | 12,360 × 8 |
| Cleaned posts | 12,000 × 32 |
| Users | 1,500 × 5 (already clean — verified, not assumed) |
| Distinct corruption mechanisms found | 9 |
| Rows dropped | 360, all full-row duplicates |
| Rows fabricated | 0 |
| Data contract violations after cleaning | 0 |

**Corruption inventory**

| Mechanism | Scale | Rule |
|---|---:|---|
| Dual missing-value encoding (`""` **and** `NULL`) | 5,309 cells | [D1](round_1/docs/cleaning_decisions.md) |
| Full-row duplicates on `post_id` | 360 | D2 |
| Mojibake (`Ã©` ← UTF-8 read as Latin-1) | 306 | D3 |
| HTML entities and inline markup | 974 | D4 |
| Injected terminal noise token, 5 variants | 1,609 | D5b |
| Null sentinels disguised by that noise | ~75 | D6 |
| Three timestamp formats in one column | 12,360 | D7 |
| Sign-flipped `likes` (min −4,987) | 509 | D9 |
| Contradictory sentiment | 329 | D14 |

---

## Three findings worth your attention

**1. Timestamp provenance is a real variable.** 3,622 rows arrived as
`dd-mm-yyyy` — date only, no clock. Parse them and discard the source format,
and every one lands at `00:00:00`. The resulting chart shows a massive midnight
posting spike that is an artefact of the ingest format, not user behaviour.
`ts_source_format` is kept as a column, and every time-of-day query filters on
it. It doubles as a fingerprint of the upstream shard.

**2. Ordering the text repairs wrong silently corrupts the hashtag analysis.**
The `Ã©` at the end of a cell is an injected marker, not a misencoded `é`
belonging to the sentence. Repair it before stripping it and the stray `é` welds
onto the final token: `#Travel` becomes `#Travelé`. The hashtag vocabulary comes
out at **56 tags instead of 29** — 27 phantoms — and every hashtag aggregate in
Phase 2 is quietly wrong while looking entirely plausible. Stripping the terminal
token first fixes it.

**3. There are no statistical outliers, and that is the finding.** Z-score and
IQR sweeps within each platform both return zero. An anomaly section built on
`IQR(likes)` finds nothing here. The real anomalies are structural (corruption
applied per-column, confirmed by a chi-square test on the missingness cross-tab),
provenance-driven (finding 1), and semantic — 329 posts pair a negative opener
with a positive verdict, e.g. *"Bummed out with my new Air Max from Nike!
Absolutely loving it."* Because the corpus draws openers and verdicts from closed
vocabularies, a lexicon match detects these exactly, with no threshold and no
false positives.

---

## Reproduce

```bash
git clone https://github.com/USER/datavortex26.git
cd datavortex26/round_1
pip install -r requirements.txt

python src/run_pipeline.py     # raw -> processed, with a printed audit trail
python src/validate.py         # enforce the data contract
python -m pytest tests -q      # unit tests for every cleaning primitive
```

The pipeline is deterministic: same inputs, byte-identical outputs. CI re-runs
all four steps on every push, so a regression fails the build instead of
reaching the report.

### Phase 2 (SQL Server / SSMS)

Run in order:

```
sql/00_create_db.sql            database + staging schema
sql/01_schema.sql               4 normalised tables, constraints, computed column
sql/02_load.sql                 BULK INSERT (CODEPAGE 65001) + load verification
sql/03_constraints_indexes.sql  indexes + integrity audit
sql/04_queries_trend.sql        moving averages, MoM growth, hashtag lifecycle
sql/05_queries_anomaly.sql      z-scores, contradiction, missingness structure
sql/06_queries_grouping.sql     NTILE cohorts, archetypes, PIVOT, co-occurrence
sql/07_queries_correlation.sql  Pearson from first principles, Spearman, sensitivity
sql/08_views_procs.sql          3 views, 2 procedures, 1 inline TVF
```

Edit `@root` in `02_load.sql` to point at `round_1/data/processed/`. The path
must be readable by the **SQL Server service account**, not just your Windows
login.

---

## Layout

```
round_1/
├── data/
│   ├── raw/          recovered from Archive Node 07, never modified
│   ├── interim/      staging
│   └── processed/    posts_clean.csv/.json, users_clean.csv,
│                     hashtags.csv, post_hashtags.csv, cleaning_audit.csv
├── docs/
│   ├── cleaning_decisions.md   every rule, every rejected alternative, and why
│   ├── data_dictionary.md      schema of every output column
│   └── site_recon.md           how the dataset was recovered
├── notebooks/
│   ├── 01_discovery_profiling.ipynb   profile the corruption BEFORE writing rules
│   ├── 02_cleaning.ipynb              apply and audit
│   └── 03_eda.ipynb                   exploratory analysis
├── src/
│   ├── config.py         paths, lexicons, catalogues — no magic literals elsewhere
│   ├── clean.py          pure cleaning primitives
│   ├── features.py       feature engineering + anomaly detection
│   ├── validate.py       the data contract
│   └── run_pipeline.py   orchestrator, emits cleaning_audit.csv
├── sql/                  Phase 2, 00–08
├── tests/                unit tests
└── reports/              EDA report, Phase 2 insight report, figures
```

---

## Method notes

**Fabrication.** Zero values were invented. Missing `platform` became an explicit
`Unknown` category rather than being inferred from author or wording — there is
no deterministic mapping, so any guess would manufacture 1,784 data points.
Negative `likes` were nulled and imputed, not `abs()`-ed; taking the absolute
value assumes a sign-bit flip we cannot evidence and would inject a fabricated
magnitude of up to 4,987.

**Imputation is labelled.** All 2,323 imputed `likes` carry `likes_imputed = 1`
from the CSV through to the SQL table. Every correlation in Phase 2 filters them
out, and `sql/07` computes one coefficient both ways to show the size of the
error that ignoring the flag would cause. Imputation is group-wise
(`platform × ts_source_format`), because a global median would flatten the
between-platform signal the analysis is trying to measure.

**Negative results are reported.** Zero statistical outliers. Near-zero
correlation between `likes`, `shares` and `comments`. Language independent of
country. Each is stated plainly rather than massaged into a narrative — and each
is itself evidence about how the corpus was generated.

**Every claim is checked.** `src/validate.py` enforces uniqueness, domain
membership, the corpus date window, non-negativity, the absence of surviving
markup or sentinels, referential integrity, and temporal coherence. The same
contract is re-asserted in SQL as `CHECK` constraints plus an integrity audit in
`03_constraints_indexes.sql`, so a bad load cannot masquerade as a bad analysis.

**Assumptions are written down.** All seven are listed at the end of
[`cleaning_decisions.md`](round_1/docs/cleaning_decisions.md), including the
evidence for day-first date ordering and the derivation of the brand/product
catalogue from the corpus itself rather than from outside knowledge.

---

## Submission checklist

**Phase 1** — deadline 14 Sep 2026, 23:59

- [x] Cleaned dataset (CSV **and** JSON)
- [ ] EDA report (PDF) — export `notebooks/03_eda.ipynb` to `reports/EDA_Report.pdf`
- [x] Code notebook / GitHub repository
- [x] Cleaning code, documented
- [x] Reproducible workflow
- [ ] Google Form submitted

**Phase 2** — deadline 15 Sep 2026, 23:59

- [x] SQL queries (`sql/04`–`sql/08`)
- [ ] Output screenshots — SSMS grid **with the query text visible in the same frame**
- [x] Logic explanation (inline in every `.sql` file)
- [ ] Phase 2 insight report (PDF) → `reports/`
- [ ] Google Form submitted
