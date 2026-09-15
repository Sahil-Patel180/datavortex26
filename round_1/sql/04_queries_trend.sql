/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   04 - Trend detection

   Every result is computed from the tables. No literal is used except
   window sizes and thresholds, each of which is explained where it
   appears. Hardcoded outputs are a disqualification under the rulebook.
   ===================================================================== */

USE DataVortex;
GO

/* ---------------------------------------------------------------------
   Q4.1  Daily engagement with a 7-day moving average and week-over-week
         delta, per platform.

   Logic: aggregate to (platform, day) first so the window function runs
   over ~365 rows per platform instead of 12,000; the moving average then
   smooths daily noise, and LAG(7) compares like-for-like weekdays, which
   a LAG(1) comparison cannot do.
   --------------------------------------------------------------------- */
WITH daily AS
(
    SELECT platform,
           CAST(posted_at AS DATE)              AS post_day,
           COUNT(*)                             AS post_count,
           AVG(CAST(engagement AS FLOAT))       AS avg_engagement
    FROM dbo.posts
    GROUP BY platform, CAST(posted_at AS DATE)
)
SELECT platform,
       post_day,
       post_count,
       CAST(avg_engagement AS DECIMAL(10,2)) AS avg_engagement,
       CAST(AVG(avg_engagement) OVER (
                PARTITION BY platform ORDER BY post_day
                ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS DECIMAL(10,2)) AS ma_7d,
       CAST(avg_engagement - LAG(avg_engagement, 7) OVER (
                PARTITION BY platform ORDER BY post_day) AS DECIMAL(10,2))  AS wow_delta
FROM daily
ORDER BY platform, post_day;
GO

/* ---------------------------------------------------------------------
   Q4.2  Monthly trajectory per platform, with month-over-month growth
         and a rank of which platform grew fastest each month.

   Logic: two window functions over the same partition - LAG for the
   comparison, RANK for the standings. NULLIF guards the first month,
   where the prior value is NULL and the division is undefined.
   --------------------------------------------------------------------- */
WITH monthly AS
(
    SELECT platform,
           DATEFROMPARTS(YEAR(posted_at), MONTH(posted_at), 1) AS month_start,
           COUNT(*)                       AS posts,
           SUM(CAST(engagement AS BIGINT)) AS total_engagement,
           AVG(CAST(engagement AS FLOAT))  AS avg_engagement
    FROM dbo.posts
    GROUP BY platform, DATEFROMPARTS(YEAR(posted_at), MONTH(posted_at), 1)
),
growth AS
(
    SELECT *,
           LAG(avg_engagement) OVER (PARTITION BY platform ORDER BY month_start) AS prev_avg
    FROM monthly
)
SELECT platform,
       month_start,
       posts,
       CAST(avg_engagement AS DECIMAL(10,2)) AS avg_engagement,
       CAST(100.0 * (avg_engagement - prev_avg) / NULLIF(prev_avg, 0) AS DECIMAL(6,2)) AS mom_pct,
       RANK() OVER (PARTITION BY month_start
                    ORDER BY (avg_engagement - prev_avg) DESC)                          AS growth_rank
FROM growth
ORDER BY month_start, growth_rank;
GO

/* ---------------------------------------------------------------------
   Q4.3  Hashtag lifecycle: first appearance, peak month, and whether a
         tag is still in use in the final month of the corpus.

   Logic: the bridge table makes this a join rather than a string scan.
   The corpus end date is derived with MAX(), never typed as a literal,
   so the query stays correct if the data is reloaded.
   --------------------------------------------------------------------- */
WITH bounds AS
(
    SELECT DATEFROMPARTS(YEAR(MAX(posted_at)), MONTH(MAX(posted_at)), 1) AS last_month
    FROM dbo.posts
),
tag_month AS
(
    SELECT h.tag,
           DATEFROMPARTS(YEAR(p.posted_at), MONTH(p.posted_at), 1) AS month_start,
           COUNT(*)                       AS uses,
           AVG(CAST(p.engagement AS FLOAT)) AS avg_engagement
    FROM dbo.post_hashtags ph
    JOIN dbo.hashtags h ON h.hashtag_id = ph.hashtag_id
    JOIN dbo.posts    p ON p.post_id    = ph.post_id
    GROUP BY h.tag, DATEFROMPARTS(YEAR(p.posted_at), MONTH(p.posted_at), 1)
)
SELECT tm.tag,
       MIN(tm.month_start) AS first_seen,
       MAX(tm.month_start) AS last_seen,
       SUM(tm.uses)        AS total_uses,
       MAX(CASE WHEN tm.rn = 1 THEN tm.month_start END) AS peak_month,
       MAX(CASE WHEN tm.rn = 1 THEN tm.uses       END) AS peak_uses,
       CASE WHEN MAX(tm.month_start) = (SELECT last_month FROM bounds)
            THEN 'active' ELSE 'faded' END AS lifecycle_status
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY tag ORDER BY uses DESC, month_start) AS rn
    FROM tag_month
) AS tm
GROUP BY tm.tag
ORDER BY total_uses DESC;
GO

/* ---------------------------------------------------------------------
   Q4.4  Posting rhythm: hour-of-day x day-of-week heatmap source.

   IMPORTANT: restricted to ts_source_format <> 'dd_mm_yyyy'. Those rows
   came from a DATE-ONLY source, so their time component is 00:00:00 by
   construction. Including them would manufacture a spike at hour 0 that
   is an artefact of the ingest format, not of user behaviour. This is
   the single most important filter in the whole Phase 2 set.
   --------------------------------------------------------------------- */
SELECT DATENAME(WEEKDAY, posted_at)                        AS day_of_week,
       DATEPART(WEEKDAY, posted_at)                        AS dow_sort,
       DATEPART(HOUR,    posted_at)                        AS hour_of_day,
       COUNT(*)                                            AS posts,
       CAST(AVG(CAST(engagement AS FLOAT)) AS DECIMAL(10,2)) AS avg_engagement
FROM dbo.posts
WHERE ts_source_format <> 'dd_mm_yyyy'
GROUP BY DATENAME(WEEKDAY, posted_at), DATEPART(WEEKDAY, posted_at), DATEPART(HOUR, posted_at)
ORDER BY dow_sort, hour_of_day;
GO

/* ---------------------------------------------------------------------
   Q4.5  Cumulative share of engagement by platform over time.

   Logic: a running SUM partitioned by platform, divided by the running
   grand total over the same ordering, gives each platform's share of
   everything observed up to that day - a share-of-voice curve rather
   than a level curve.
   --------------------------------------------------------------------- */
WITH daily AS
(
    SELECT platform,
           CAST(posted_at AS DATE)         AS post_day,
           SUM(CAST(engagement AS BIGINT)) AS day_engagement
    FROM dbo.posts
    GROUP BY platform, CAST(posted_at AS DATE)
),
running AS
(
    SELECT platform, post_day, day_engagement,
           SUM(day_engagement) OVER (PARTITION BY platform ORDER BY post_day
                                     ROWS UNBOUNDED PRECEDING) AS cum_platform,
           SUM(SUM(day_engagement)) OVER (ORDER BY post_day
                                          ROWS UNBOUNDED PRECEDING) AS cum_total
    FROM daily
    GROUP BY platform, post_day, day_engagement
)
SELECT platform, post_day, cum_platform, cum_total,
       CAST(100.0 * cum_platform / NULLIF(cum_total, 0) AS DECIMAL(6,3)) AS pct_share
FROM running
ORDER BY post_day, platform;
GO
