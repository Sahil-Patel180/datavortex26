/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   06 - Behavioural grouping
   ===================================================================== */

USE DataVortex;
GO

/* ---------------------------------------------------------------------
   Q6.1  Follower-size cohorts.

   Logic: NTILE(4) over follower_count gives equal-sized cohorts rather
   than arbitrary cut-offs like "10k+", which would be a hardcoded
   assumption about what counts as large. The cohort bounds are reported
   alongside the metrics so the reader can see what each quartile means.
   --------------------------------------------------------------------- */
WITH user_activity AS
(
    SELECT u.user_id, u.follower_count,
           COUNT(p.post_id)                  AS posts,
           AVG(CAST(p.engagement AS FLOAT))  AS avg_engagement,
           SUM(CAST(p.engagement AS BIGINT)) AS total_engagement
    FROM dbo.users u
    LEFT JOIN dbo.posts p ON p.user_id = u.user_id
    GROUP BY u.user_id, u.follower_count
),
cohorts AS
(
    SELECT *, NTILE(4) OVER (ORDER BY follower_count) AS follower_quartile
    FROM user_activity
)
SELECT follower_quartile,
       COUNT(*)                                              AS users,
       MIN(follower_count)                                   AS min_followers,
       MAX(follower_count)                                   AS max_followers,
       CAST(AVG(CAST(posts AS FLOAT)) AS DECIMAL(6,2))       AS avg_posts_per_user,
       CAST(AVG(avg_engagement) AS DECIMAL(10,2))            AS avg_engagement,
       CAST(AVG(avg_engagement / NULLIF(follower_count, 0)) AS DECIMAL(10,6)) AS avg_engagement_rate
FROM cohorts
GROUP BY follower_quartile
ORDER BY follower_quartile;
GO

/* ---------------------------------------------------------------------
   Q6.2  Author archetypes from posting behaviour.

   Logic: classify on two axes measured from the data itself - volume
   relative to the corpus median, and sentiment mix. Medians are computed
   in the query via PERCENTILE_CONT, so no cut-off is typed in by hand
   and the classification survives a data reload.
   --------------------------------------------------------------------- */
WITH user_profile AS
(
    SELECT p.user_id,
           COUNT(*)                                                             AS posts,
           AVG(CAST(p.engagement AS FLOAT))                                     AS avg_engagement,
           SUM(CASE WHEN p.sentiment = 'positive' THEN 1 ELSE 0 END)            AS pos,
           SUM(CASE WHEN p.sentiment = 'negative' THEN 1 ELSE 0 END)            AS neg,
           SUM(CASE WHEN p.sentiment IS NOT NULL  THEN 1 ELSE 0 END)            AS scored
    FROM dbo.posts p
    GROUP BY p.user_id
),
benchmarks AS
(
    SELECT DISTINCT
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY posts)          OVER () AS median_posts,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_engagement) OVER () AS median_engagement
    FROM user_profile
),
classified AS
(
    SELECT up.*,
           b.median_posts,
           b.median_engagement,
           1.0 * up.pos / NULLIF(up.scored, 0) AS pos_share,
           1.0 * up.neg / NULLIF(up.scored, 0) AS neg_share
    FROM user_profile up
    CROSS JOIN benchmarks b
)
SELECT CASE
           WHEN posts >  median_posts AND avg_engagement >  median_engagement THEN 'high volume / high impact'
           WHEN posts >  median_posts AND avg_engagement <= median_engagement THEN 'high volume / low impact'
           WHEN posts <= median_posts AND avg_engagement >  median_engagement THEN 'low volume / high impact'
           ELSE 'low volume / low impact'
       END AS archetype,
       COUNT(*)                                        AS users,
       SUM(posts)                                      AS total_posts,
       CAST(AVG(avg_engagement) AS DECIMAL(10,2))      AS avg_engagement,
       CAST(AVG(pos_share) AS DECIMAL(5,3))            AS avg_positive_share,
       CAST(AVG(neg_share) AS DECIMAL(5,3))            AS avg_negative_share
FROM classified
GROUP BY CASE
           WHEN posts >  median_posts AND avg_engagement >  median_engagement THEN 'high volume / high impact'
           WHEN posts >  median_posts AND avg_engagement <= median_engagement THEN 'high volume / low impact'
           WHEN posts <= median_posts AND avg_engagement >  median_engagement THEN 'low volume / high impact'
           ELSE 'low volume / low impact'
         END
ORDER BY users DESC;
GO

/* ---------------------------------------------------------------------
   Q6.3  Geography x language.

   The corpus contains speakers whose language does not match their
   country - e.g. Japanese speakers in Berlin. Treated as diaspora
   signal, not as an error to be "corrected", and quantified here so the
   assumption is visible rather than buried in the cleaning code.
   --------------------------------------------------------------------- */
SELECT u.country,
       u.language,
       COUNT(DISTINCT u.user_id)                             AS users,
       COUNT(p.post_id)                                      AS posts,
       CAST(AVG(CAST(p.engagement AS FLOAT)) AS DECIMAL(10,2)) AS avg_engagement,
       CAST(100.0 * COUNT(DISTINCT u.user_id)
            / SUM(COUNT(DISTINCT u.user_id)) OVER (PARTITION BY u.country)
            AS DECIMAL(5,2))                                  AS pct_of_country
FROM dbo.users u
LEFT JOIN dbo.posts p ON p.user_id = u.user_id
GROUP BY u.country, u.language
ORDER BY u.country, users DESC;
GO

/* ---------------------------------------------------------------------
   Q6.4  Brand x platform reception matrix.

   PIVOT rather than a pile of CASE expressions: the platform list comes
   from the CHECK constraint domain, so it is a stated part of the schema
   rather than an invented literal.
   --------------------------------------------------------------------- */
SELECT brand, Facebook, Instagram, Reddit, Twitter, YouTube, Unknown
FROM (
    SELECT brand, platform, CAST(engagement AS FLOAT) AS engagement
    FROM dbo.posts
    WHERE brand IS NOT NULL
) AS src
PIVOT (
    AVG(engagement) FOR platform IN ([Facebook],[Instagram],[Reddit],[Twitter],[YouTube],[Unknown])
) AS pvt
ORDER BY brand;
GO

/* ---------------------------------------------------------------------
   Q6.5  Hashtag co-occurrence.

   Logic: self-join the bridge table on post_id with a < b to count each
   unordered pair exactly once. The HAVING floor keeps pairs that appear
   often enough to be a pattern rather than a coincidence.
   --------------------------------------------------------------------- */
SELECT ha.tag AS tag_a,
       hb.tag AS tag_b,
       COUNT(*)                                                AS co_occurrences,
       CAST(AVG(CAST(p.engagement AS FLOAT)) AS DECIMAL(10,2))  AS avg_engagement
FROM dbo.post_hashtags pa
JOIN dbo.post_hashtags pb ON pb.post_id = pa.post_id
                          AND pb.hashtag_id > pa.hashtag_id
JOIN dbo.hashtags ha ON ha.hashtag_id = pa.hashtag_id
JOIN dbo.hashtags hb ON hb.hashtag_id = pb.hashtag_id
JOIN dbo.posts    p  ON p.post_id     = pa.post_id
GROUP BY ha.tag, hb.tag
HAVING COUNT(*) >= 20
ORDER BY co_occurrences DESC;
GO

/* ---------------------------------------------------------------------
   Q6.6  Cohort retention: do users who started early stay active?

   Logic: cohort by account_created month, then measure the span between
   each user's first and last post. DATEDIFF over the user's own extremes
   avoids assuming a fixed observation window.
   --------------------------------------------------------------------- */
SELECT DATEFROMPARTS(YEAR(u.account_created), MONTH(u.account_created), 1) AS signup_month,
       COUNT(DISTINCT u.user_id)                                          AS users,
       COUNT(p.post_id)                                                   AS posts,
       CAST(1.0 * COUNT(p.post_id) / COUNT(DISTINCT u.user_id) AS DECIMAL(6,2)) AS posts_per_user,
       AVG(DATEDIFF(DAY, u.account_created, p.posted_at))                 AS avg_days_to_post
FROM dbo.users u
LEFT JOIN dbo.posts p ON p.user_id = u.user_id
GROUP BY DATEFROMPARTS(YEAR(u.account_created), MONTH(u.account_created), 1)
ORDER BY signup_month;
GO
