# Reports

| File | Deadline | How to produce |
|---|---|---|
| `EDA_Report.pdf` | Phase 1 — 14 Sep, 23:59 | export `notebooks/03_eda.ipynb` |
| `Phase2_Insight_Report.pdf` | Phase 2 — 15 Sep, 23:59 | fill in `Phase2_Insight_Report.md`, export |
| `figures/` | — | written automatically by notebooks 01 and 03 |

## Exporting the EDA report

Run all cells first so every figure is embedded, then:

```bash
cd round_1
jupyter nbconvert --to pdf --execute notebooks/03_eda.ipynb \
  --output-dir reports --output EDA_Report
```

No LaTeX installed? Go via HTML and print to PDF from the browser:

```bash
jupyter nbconvert --to html --execute notebooks/03_eda.ipynb \
  --output-dir reports --output EDA_Report
```

## Screenshot rules for Phase 2

The rulebook treats hardcoded outputs as a disqualification, so each screenshot
has to prove the number was computed:

- Query text and result grid **in the same frame**.
- Row count visible in the SSMS status bar.
- Full-resolution PNG, readable at 100%. No phone photos of a monitor.
- One screenshot per query, named `q5_2_contradiction.png` to match the report.
