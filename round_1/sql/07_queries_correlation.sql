/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   07 - Correlation analysis

   SQL Server has no built-in CORR(), so Pearson's r is computed from its
   definition using SUM aggregates. Every coefficient below is calculated
   from the rows; nothing is transcribed from the Python EDA.

   STANDING RULE: every correlation involving `likes` filters
   likes_imputed = 0. An imputed like is a group median, so 2,323 rows
   would otherwise share a handful of identical values, artificially
   tightening any relationship they take part in. Q7.4 measures exactly
   how much damage ignoring this would do.
   ===================================================================== */

USE DataVortex;
GO

/* ---------------------------------------------------------------------
   Q7.1  Pairwise Pearson correlation across the engagement metrics.

   Logic: UNPIVOT-free approach - one CTE per pair would be repetitive, so
   the aggregates are computed once and the coefficient formula is applied
   three times over the same scan.
   --------------------------------------------------------------------- */
WITH observed AS
(
    SELECT CAST(likes AS FLOAT) AS x1, CAST(shares AS FLOAT) AS x2, CAST(comments AS FLOAT) AS x3
    FROM dbo.posts
    WHERE likes_imputed = 0
),
agg AS
(
    SELECT COUNT(*) AS n,
           SUM(x1) AS s1, SUM(x2) AS s2, SUM(x3) AS s3,
           SUM(x1*x1) AS q1, SUM(x2*x2) AS q2, SUM(x3*x3) AS q3,
           SUM(x1*x2) AS p12, SUM(x1*x3) AS p13, SUM(x2*x3) AS p23
    FROM observed
)
SELECT 'likes ~ shares' AS pair, n AS observations,
       CAST((n*p12 - s1*s2) / NULLIF(SQRT(n*q1 - s1*s1) * SQRT(n*q2 - s2*s2), 0) AS DECIMAL(7,4)) AS pearson_r
FROM agg
UNION ALL
SELECT 'likes ~ comments', n,
       CAST((n*p13 - s1*s3) / NULLIF(SQRT(n*q1 - s1*s1) * SQRT(n*q3 - s3*s3), 0) AS DECIMAL(7,4))
FROM agg
UNION ALL
SELECT 'shares ~ comments', n,
       CAST((n*p23 - s2*s3) / NULLIF(SQRT(n*q2 - s2*s2) * SQRT(n*q3 - s3*s3), 0) AS DECIMAL(7,4))
FROM agg;
GO

/* ---------------------------------------------------------------------
   Q7.2  Does follower count predict engagement?

   Reported on both the raw and the log scale. A social graph typically
   produces a sublinear power law, which shows up as a weak Pearson r on
   raw values but a much stronger one after logging. Comparing the two is
   how you tell "no relationship" apart from "non-linear relationship".
   --------------------------------------------------------------------- */
WITH paired AS
(
    SELECT CAST(u.follower_count AS FLOAT) AS followers,
           CAST(p.engagement     AS FLOAT) AS engagement
    FROM dbo.posts p
    JOIN dbo.users u ON u.user_id = p.user_id
    WHERE p.likes_imputed = 0
      AND u.follower_count > 0
      AND p.engagement     > 0
),
raw_agg AS
(
    SELECT COUNT(*) AS n, SUM(followers) AS sx, SUM(engagement) AS sy,
           SUM(followers*followers) AS sxx, SUM(engagement*engagement) AS syy,
           SUM(followers*engagement) AS sxy
    FROM paired
),
log_agg AS
(
    SELECT COUNT(*) AS n, SUM(LOG(followers)) AS sx, SUM(LOG(engagement)) AS sy,
           SUM(LOG(followers)*LOG(followers)) AS sxx,
           SUM(LOG(engagement)*LOG(engagement)) AS syy,
           SUM(LOG(followers)*LOG(engagement)) AS sxy
    FROM paired
)
SELECT 'raw scale' AS scale, n AS observations,
       CAST((n*sxy - sx*sy) / NULLIF(SQRT(n*sxx - sx*sx) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) AS pearson_r
FROM raw_agg
UNION ALL
SELECT 'log-log scale', n,
       CAST((n*sxy - sx*sy) / NULLIF(SQRT(n*sxx - sx*sx) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4))
FROM log_agg;
GO

/* ---------------------------------------------------------------------
   Q7.3  Content shape vs engagement: hashtag count, mention count,
         text length, sentiment.

   Logic: correlate each content feature against engagement within the
   same filtered population, so the coefficients are directly comparable
   to each other.
   --------------------------------------------------------------------- */
WITH base AS
(
    SELECT CAST(engagement    AS FLOAT) AS y,
           CAST(hashtag_count AS FLOAT) AS f_hash,
           CAST(mention_count AS FLOAT) AS f_mention,
           CAST(char_length   AS FLOAT) AS f_chars,
           CAST(word_count    AS FLOAT) AS f_words
    FROM dbo.posts
    WHERE likes_imputed = 0 AND text_content IS NOT NULL
),
a AS
(
    SELECT COUNT(*) AS n, SUM(y) AS sy, SUM(y*y) AS syy,
           SUM(f_hash) AS s1, SUM(f_hash*f_hash) AS q1, SUM(f_hash*y) AS p1,
           SUM(f_mention) AS s2, SUM(f_mention*f_mention) AS q2, SUM(f_mention*y) AS p2,
           SUM(f_chars) AS s3, SUM(f_chars*f_chars) AS q3, SUM(f_chars*y) AS p3,
           SUM(f_words) AS s4, SUM(f_words*f_words) AS q4, SUM(f_words*y) AS p4
    FROM base
)
SELECT 'hashtag_count ~ engagement' AS pair, n AS observations,
       CAST((n*p1 - s1*sy) / NULLIF(SQRT(n*q1 - s1*s1) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) AS pearson_r
FROM a
UNION ALL SELECT 'mention_count ~ engagement', n,
       CAST((n*p2 - s2*sy) / NULLIF(SQRT(n*q2 - s2*s2) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) FROM a
UNION ALL SELECT 'char_length ~ engagement', n,
       CAST((n*p3 - s3*sy) / NULLIF(SQRT(n*q3 - s3*s3) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) FROM a
UNION ALL SELECT 'word_count ~ engagement', n,
       CAST((n*p4 - s4*sy) / NULLIF(SQRT(n*q4 - s4*s4) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) FROM a;
GO

/* ---------------------------------------------------------------------
   Q7.4  SENSITIVITY CHECK: what imputation does to a correlation.

   The same coefficient computed twice - once on observed rows only, once
   on all rows including the 2,323 imputed likes. The gap is the size of
   the error a team makes by treating imputed values as observations.
   This query is the reason likes_imputed was carried all the way from
   Phase 1 into the database.
   --------------------------------------------------------------------- */
WITH observed AS
(
    SELECT CAST(likes AS FLOAT) AS x, CAST(shares AS FLOAT) AS y
    FROM dbo.posts WHERE likes_imputed = 0
),
everything AS
(
    SELECT CAST(likes AS FLOAT) AS x, CAST(shares AS FLOAT) AS y
    FROM dbo.posts
),
calc AS
(
    SELECT 'observed likes only' AS population, COUNT(*) AS n, SUM(x) AS sx, SUM(y) AS sy,
           SUM(x*x) AS sxx, SUM(y*y) AS syy, SUM(x*y) AS sxy FROM observed
    UNION ALL
    SELECT 'including imputed', COUNT(*), SUM(x), SUM(y), SUM(x*x), SUM(y*y), SUM(x*y) FROM everything
)
SELECT population, n AS observations,
       CAST((n*sxy - sx*sy) / NULLIF(SQRT(n*sxx - sx*sx) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) AS pearson_r,
       CAST(sx / n AS DECIMAL(10,2)) AS mean_likes,
       CAST(SQRT((sxx - sx*sx/n) / NULLIF(n - 1, 0)) AS DECIMAL(10,2)) AS stdev_likes
FROM calc;
GO

/* ---------------------------------------------------------------------
   Q7.5  Spearman rank correlation (monotonic, outlier-resistant).

   Logic: replace each value with its RANK, then apply the same Pearson
   formula. Comparing Spearman against Pearson from Q7.1 separates a
   genuinely linear relationship from a merely monotonic one.
   AVG-style tie handling is approximated by RANK(); with 12,000 rows over
   a wide integer range, ties are rare enough not to move the result
   materially - stated here rather than left implicit.
   --------------------------------------------------------------------- */
WITH ranked AS
(
    SELECT CAST(RANK() OVER (ORDER BY likes)  AS FLOAT) AS rx,
           CAST(RANK() OVER (ORDER BY shares) AS FLOAT) AS ry
    FROM dbo.posts
    WHERE likes_imputed = 0
),
a AS
(
    SELECT COUNT(*) AS n, SUM(rx) AS sx, SUM(ry) AS sy,
           SUM(rx*rx) AS sxx, SUM(ry*ry) AS syy, SUM(rx*ry) AS sxy
    FROM ranked
)
SELECT 'likes ~ shares (Spearman)' AS pair, n AS observations,
       CAST((n*sxy - sx*sy) / NULLIF(SQRT(n*sxx - sx*sx) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) AS spearman_rho
FROM a;
GO

/* ---------------------------------------------------------------------
   Q7.6  Does sentiment move engagement?

   Correlation needs numbers, so the ordinal verdict_polarity (-1/0/+1)
   is used directly. Group means are reported alongside so the reader can
   see the effect size, not just the coefficient.
   --------------------------------------------------------------------- */
SELECT sentiment,
       COUNT(*)                                                 AS posts,
       CAST(AVG(CAST(engagement AS FLOAT)) AS DECIMAL(10,2))     AS avg_engagement,
       CAST(STDEV(CAST(engagement AS FLOAT)) AS DECIMAL(10,2))   AS stdev_engagement,
       CAST(MIN(engagement) AS INT)                              AS min_engagement,
       CAST(MAX(engagement) AS INT)                              AS max_engagement
FROM dbo.posts
WHERE likes_imputed = 0 AND sentiment IS NOT NULL
GROUP BY sentiment
ORDER BY avg_engagement DESC;
GO

WITH base AS
(
    SELECT CAST(verdict_polarity AS FLOAT) AS x, CAST(engagement AS FLOAT) AS y
    FROM dbo.posts
    WHERE likes_imputed = 0 AND verdict_polarity IS NOT NULL
),
a AS
(
    SELECT COUNT(*) AS n, SUM(x) AS sx, SUM(y) AS sy,
           SUM(x*x) AS sxx, SUM(y*y) AS syy, SUM(x*y) AS sxy
    FROM base
)
SELECT 'verdict_polarity ~ engagement' AS pair, n AS observations,
       CAST((n*sxy - sx*sy) / NULLIF(SQRT(n*sxx - sx*sx) * SQRT(n*syy - sy*sy), 0) AS DECIMAL(7,4)) AS pearson_r
FROM a;
GO
