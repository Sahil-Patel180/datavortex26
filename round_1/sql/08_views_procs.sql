/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   08 - Views, stored procedures, table-valued function

   The rulebook explicitly permits CTEs, window functions, views and
   procedures. These are not decoration: each one removes a join or a
   filter that would otherwise be retyped in every analysis query, which
   is where quiet inconsistencies creep in.
   ===================================================================== */

USE DataVortex;
GO

/* =====================================================================
   VIEW 1 - the analysis surface.
   Joins posts to their author once, exposes engagement_rate, and derives
   the temporal parts. Every downstream query reads this instead of
   repeating the join, so a change to the definition propagates
   everywhere at once.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_post_enriched
AS
SELECT p.post_id,
       p.user_id,
       p.platform,
       p.text_content,
       p.posted_at,
       p.ts_source_format,
       p.likes,
       p.likes_imputed,
       p.shares,
       p.comments,
       p.engagement,
       CAST(p.engagement AS FLOAT) / NULLIF(u.follower_count, 0) AS engagement_rate,
       p.sentiment,
       p.verdict_polarity,
       p.is_contradictory,
       p.brand,
       p.product,
       p.hashtag_count,
       p.mention_count,
       p.char_length,
       p.word_count,
       u.city,
       u.country,
       u.language,
       u.follower_count,
       u.account_created,
       CAST(p.posted_at AS DATE)                                  AS post_date,
       DATEFROMPARTS(YEAR(p.posted_at), MONTH(p.posted_at), 1)    AS post_month,
       DATEPART(HOUR, p.posted_at)                                AS post_hour,
       DATENAME(WEEKDAY, p.posted_at)                             AS post_dow,
       CASE WHEN DATEPART(WEEKDAY, p.posted_at) IN (1, 7) THEN 1 ELSE 0 END AS is_weekend,
       /* Hour is only interpretable when the source carried a time part. */
       CASE WHEN p.ts_source_format = 'dd_mm_yyyy' THEN 0 ELSE 1 END        AS has_real_time
FROM dbo.posts p
JOIN dbo.users u ON u.user_id = p.user_id;
GO

/* =====================================================================
   VIEW 2 - the clean analytical population.
   Observed likes, real text, known platform. This is the population for
   any statement about relationships between variables; the full table
   stays available for statements about volume and coverage.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_analysis_ready
AS
SELECT *
FROM dbo.vw_post_enriched
WHERE likes_imputed = 0
  AND text_content IS NOT NULL
  AND platform <> 'Unknown';
GO

/* =====================================================================
   VIEW 3 - data quality scorecard.
   One row per dimension, so the state of the corpus can be screenshotted
   in a single query for the Phase 2 report.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_data_quality
AS
SELECT 'total posts'            AS metric, COUNT(*)                                        AS value FROM dbo.posts
UNION ALL SELECT 'total users',           COUNT(*)                                         FROM dbo.users
UNION ALL SELECT 'posts with imputed likes',  SUM(CAST(likes_imputed AS INT))              FROM dbo.posts
UNION ALL SELECT 'posts with missing text',   SUM(CASE WHEN text_content IS NULL THEN 1 ELSE 0 END) FROM dbo.posts
UNION ALL SELECT 'posts with unknown platform', SUM(CASE WHEN platform = 'Unknown' THEN 1 ELSE 0 END) FROM dbo.posts
UNION ALL SELECT 'contradictory sentiment',  SUM(CAST(is_contradictory AS INT))            FROM dbo.posts
UNION ALL SELECT 'date-only timestamps',     SUM(CASE WHEN ts_source_format = 'dd_mm_yyyy' THEN 1 ELSE 0 END) FROM dbo.posts
UNION ALL SELECT 'fully clean posts',        COUNT(*)                                      FROM dbo.vw_analysis_ready
UNION ALL SELECT 'distinct hashtags',        COUNT(*)                                      FROM dbo.hashtags
UNION ALL SELECT 'hashtag assignments',      COUNT(*)                                      FROM dbo.post_hashtags;
GO

/* =====================================================================
   PROC 1 - top brands per platform.
   @top is a parameter rather than a literal so the caller controls the
   cut-off; the ranking itself is computed, never listed.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_top_brands_by_platform
    @top          INT = 3,
    @min_posts    INT = 20,
    @observed_only BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    WITH brand_stats AS
    (
        SELECT platform, brand,
               COUNT(*)                       AS posts,
               AVG(CAST(engagement AS FLOAT)) AS avg_engagement
        FROM dbo.vw_post_enriched
        WHERE brand IS NOT NULL
          AND (@observed_only = 0 OR likes_imputed = 0)
        GROUP BY platform, brand
        HAVING COUNT(*) >= @min_posts
    ),
    ranked AS
    (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY platform ORDER BY avg_engagement DESC) AS rn
        FROM brand_stats
    )
    SELECT platform, rn AS rank, brand, posts,
           CAST(avg_engagement AS DECIMAL(10,2)) AS avg_engagement
    FROM ranked
    WHERE rn <= @top
    ORDER BY platform, rn;
END;
GO

/* =====================================================================
   PROC 2 - anomaly report for an arbitrary window.
   Every count is derived from the window passed in; nothing is cached or
   precomputed, so the procedure cannot return a stale number.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_anomaly_report
    @from DATE = NULL,
    @to   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @from = COALESCE(@from, CAST(MIN(posted_at) AS DATE)),
           @to   = COALESCE(@to,   CAST(MAX(posted_at) AS DATE))
    FROM dbo.posts;

    WITH windowed AS
    (
        SELECT * FROM dbo.posts
        WHERE CAST(posted_at AS DATE) BETWEEN @from AND @to
    ),
    stats AS
    (
        SELECT platform, AVG(CAST(engagement AS FLOAT)) AS mu,
                         STDEV(CAST(engagement AS FLOAT)) AS sd
        FROM windowed GROUP BY platform
    )
    SELECT @from AS window_from,
           @to   AS window_to,
           w.platform,
           COUNT(*)                                                              AS posts,
           SUM(CAST(w.is_contradictory AS INT))                                  AS contradictory_sentiment,
           SUM(CASE WHEN w.shares > w.likes AND w.likes_imputed = 0 THEN 1 ELSE 0 END) AS shares_exceed_likes,
           SUM(CAST(w.likes_imputed AS INT))                                     AS imputed_likes,
           SUM(CASE WHEN w.text_content IS NULL THEN 1 ELSE 0 END)               AS missing_text,
           SUM(CASE WHEN ABS((CAST(w.engagement AS FLOAT) - s.mu) / NULLIF(s.sd, 0)) > 3
                    THEN 1 ELSE 0 END)                                           AS beyond_3_sigma
    FROM windowed w
    JOIN stats s ON s.platform = w.platform
    GROUP BY w.platform
    ORDER BY w.platform;
END;
GO

/* =====================================================================
   FUNCTION - engagement percentile band for a given platform.
   Inline table-valued, so the optimiser folds it into the calling query
   rather than executing it row by row the way a scalar UDF would.
   ===================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_platform_percentiles (@platform VARCHAR(20))
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (1)
           @platform AS platform,
           PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY CAST(engagement AS FLOAT)) OVER () AS p25,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY CAST(engagement AS FLOAT)) OVER () AS p50,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY CAST(engagement AS FLOAT)) OVER () AS p75,
           PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CAST(engagement AS FLOAT)) OVER () AS p95
    FROM dbo.posts
    WHERE platform = @platform
);
GO

/* --------------------------------------------------------------------
   Smoke test - run these to confirm the objects work, and screenshot
   the output for the Phase 2 report.
   -------------------------------------------------------------------- */
SELECT * FROM dbo.vw_data_quality;
GO
EXEC dbo.usp_top_brands_by_platform @top = 3;
GO
EXEC dbo.usp_anomaly_report;
GO
SELECT * FROM dbo.fn_platform_percentiles('Reddit');
GO
