/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   05 - Anomaly discovery

   Thresholds are stated and defended, never tuned until something
   appears. Where a query returns nothing, that null result is reported
   as a finding rather than relaxed away.
   ===================================================================== */

USE DataVortex;
GO

/* ---------------------------------------------------------------------
   Q5.1  Within-platform z-score of engagement.

   Logic: platforms have different engagement scales, so a global z-score
   would flag an ordinary YouTube post simply because YouTube runs hot.
   Grouping first removes that confound. |z| > 3 is the conventional
   three-sigma rule, chosen before looking at the output.

   NULLIF(sd, 0) guards a single-row platform, where the standard
   deviation is NULL and the division would error.
   --------------------------------------------------------------------- */
WITH platform_stats AS
(
    SELECT platform,
           AVG(CAST(engagement AS FLOAT))   AS mu,
           STDEV(CAST(engagement AS FLOAT)) AS sd,
           COUNT(*)                         AS n
    FROM dbo.posts
    GROUP BY platform
),
scored AS
(
    SELECT p.post_id, p.platform, p.engagement, p.likes_imputed,
           (CAST(p.engagement AS FLOAT) - s.mu) / NULLIF(s.sd, 0) AS z
    FROM dbo.posts p
    JOIN platform_stats s ON s.platform = p.platform
)
SELECT platform,
       COUNT(*)                                                  AS posts,
       SUM(CASE WHEN ABS(z) > 3 THEN 1 ELSE 0 END)               AS beyond_3_sigma,
       SUM(CASE WHEN ABS(z) > 2 THEN 1 ELSE 0 END)               AS beyond_2_sigma,
       CAST(MAX(ABS(z)) AS DECIMAL(6,3))                         AS max_abs_z
FROM scored
GROUP BY platform
ORDER BY platform;
GO

/* Detail rows, if any exist. An empty result set here is the finding:
   engagement is near-uniform within its bounds, which is consistent with
   synthetic generation rather than organic behaviour. */
WITH platform_stats AS
(
    SELECT platform, AVG(CAST(engagement AS FLOAT)) AS mu,
                     STDEV(CAST(engagement AS FLOAT)) AS sd
    FROM dbo.posts GROUP BY platform
)
SELECT TOP (50)
       p.post_id, p.platform, p.engagement,
       CAST((CAST(p.engagement AS FLOAT) - s.mu) / NULLIF(s.sd, 0) AS DECIMAL(6,3)) AS z
FROM dbo.posts p
JOIN platform_stats s ON s.platform = p.platform
WHERE ABS((CAST(p.engagement AS FLOAT) - s.mu) / NULLIF(s.sd, 0)) > 3
ORDER BY ABS((CAST(p.engagement AS FLOAT) - s.mu) / NULLIF(s.sd, 0)) DESC;
GO

/* ---------------------------------------------------------------------
   Q5.2  Semantic anomaly: contradictory sentiment.

   A negative opening clause paired with a positive verdict - "Bummed out
   with my new Air Max from Nike! Absolutely loving it." A single author
   cannot hold both positions in one sentence, so these are injected
   noise. No threshold is involved: the corpus draws openers and verdicts
   from closed vocabularies, so the lexicon match is exact.

   This is the anomaly class that a numeric outlier sweep cannot see, and
   Q5.1 confirms the numeric sweep finds nothing at all.
   --------------------------------------------------------------------- */
SELECT platform,
       COUNT(*)                                                       AS posts,
       SUM(CAST(is_contradictory AS INT))                             AS contradictory,
       CAST(100.0 * SUM(CAST(is_contradictory AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS pct,
       CAST(AVG(CASE WHEN is_contradictory = 1
                     THEN CAST(engagement AS FLOAT) END) AS DECIMAL(10,2))         AS avg_eng_contradictory,
       CAST(AVG(CASE WHEN is_contradictory = 0
                     THEN CAST(engagement AS FLOAT) END) AS DECIMAL(10,2))         AS avg_eng_clean
FROM dbo.posts
GROUP BY platform
WITH ROLLUP
ORDER BY GROUPING(platform), platform;
GO

/* Is the contradiction uniformly spread, or concentrated? If it tracks
   the corruption rather than the content, it should be independent of
   brand and platform - which is itself testable. */
SELECT brand,
       COUNT(*)                           AS posts,
       SUM(CAST(is_contradictory AS INT)) AS contradictory,
       CAST(100.0 * SUM(CAST(is_contradictory AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS pct
FROM dbo.posts
WHERE brand IS NOT NULL
GROUP BY brand
ORDER BY pct DESC;
GO

/* ---------------------------------------------------------------------
   Q5.3  Missingness structure: was the corruption applied row-wise or
         column-wise?

   Logic: cross-tabulate the two damaged columns. If corruption hit whole
   rows, missing platform and missing text would co-occur far more often
   than chance. If it hit columns independently, the cross-tab will look
   like the product of the marginals. The expected-count column makes
   that comparison explicit instead of eyeballing it.
   --------------------------------------------------------------------- */
WITH flags AS
(
    SELECT CASE WHEN platform = 'Unknown'   THEN 1 ELSE 0 END AS platform_missing,
           CASE WHEN text_content IS NULL   THEN 1 ELSE 0 END AS text_missing,
           CAST(likes_imputed AS INT)                         AS likes_missing
    FROM dbo.posts
),
totals AS (SELECT COUNT(*) AS n FROM flags)
SELECT f.platform_missing,
       f.text_missing,
       COUNT(*) AS observed,
       CAST(1.0 * SUM(COUNT(*)) OVER (PARTITION BY f.platform_missing)
                * SUM(COUNT(*)) OVER (PARTITION BY f.text_missing)
                / (SELECT n FROM totals) AS DECIMAL(10,1)) AS expected_if_independent
FROM flags f
GROUP BY f.platform_missing, f.text_missing
ORDER BY f.platform_missing, f.text_missing;
GO

/* ---------------------------------------------------------------------
   Q5.4  Behavioural implausibility: shares outrunning likes.

   On real platforms a share costs more effort than a like, so
   shares > likes is rare. Restricted to observed likes only - an imputed
   like is a group median and cannot evidence anything about this row.
   --------------------------------------------------------------------- */
SELECT platform,
       COUNT(*)                                                        AS observed_posts,
       SUM(CASE WHEN shares > likes THEN 1 ELSE 0 END)                 AS shares_exceed_likes,
       CAST(100.0 * SUM(CASE WHEN shares > likes THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,2))                                AS pct,
       CAST(AVG(CAST(shares AS FLOAT) / NULLIF(likes, 0)) AS DECIMAL(8,4)) AS mean_share_like_ratio
FROM dbo.posts
WHERE likes_imputed = 0
GROUP BY platform
ORDER BY pct DESC;
GO

/* ---------------------------------------------------------------------
   Q5.5  Authors whose behaviour deviates from their follower cohort.

   Logic: NTILE puts users into follower deciles, then each user's mean
   engagement rate is compared with their own decile's mean. Comparing
   against the global mean would just rediscover that big accounts get
   more engagement; comparing within-decile isolates genuine over- and
   under-performance.
   --------------------------------------------------------------------- */
WITH user_stats AS
(
    SELECT u.user_id, u.country, u.follower_count,
           COUNT(p.post_id)                                                  AS posts,
           AVG(CAST(p.engagement AS FLOAT) / NULLIF(u.follower_count, 0))     AS avg_eng_rate
    FROM dbo.users u
    JOIN dbo.posts p ON p.user_id = u.user_id
    GROUP BY u.user_id, u.country, u.follower_count
    HAVING COUNT(p.post_id) >= 3          -- fewer than 3 posts is noise, not a pattern
),
decile AS
(
    SELECT *, NTILE(10) OVER (ORDER BY follower_count) AS follower_decile
    FROM user_stats
),
decile_stats AS
(
    SELECT follower_decile,
           AVG(avg_eng_rate)   AS decile_mean,
           STDEV(avg_eng_rate) AS decile_sd
    FROM decile
    GROUP BY follower_decile
)
SELECT TOP (25)
       d.user_id, d.country, d.follower_count, d.posts,
       d.follower_decile,
       CAST(d.avg_eng_rate AS DECIMAL(10,5))  AS avg_eng_rate,
       CAST(ds.decile_mean AS DECIMAL(10,5))  AS decile_mean,
       CAST((d.avg_eng_rate - ds.decile_mean) / NULLIF(ds.decile_sd, 0) AS DECIMAL(6,3)) AS z_within_decile
FROM decile d
JOIN decile_stats ds ON ds.follower_decile = d.follower_decile
ORDER BY ABS((d.avg_eng_rate - ds.decile_mean) / NULLIF(ds.decile_sd, 0)) DESC;
GO
