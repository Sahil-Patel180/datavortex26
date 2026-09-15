/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   03 - Indexes + post-load integrity audit

   Indexes are created AFTER the bulk load, not before: building them on
   an empty table then inserting 12,000 rows makes SQL Server maintain
   every B-tree per row. Load flat, index once.
   ===================================================================== */

USE DataVortex;
GO

/* --------------------------------------------------------------------
   Indexes, each justified by a query in 04-08.
   -------------------------------------------------------------------- */

/* Trend queries slice by platform then scan a date range; INCLUDE makes
   the aggregates covering so the clustered index is never touched. */
CREATE NONCLUSTERED INDEX ix_posts_platform_date
    ON dbo.posts (platform, posted_at)
    INCLUDE (likes, shares, comments, engagement, likes_imputed);
GO

/* Per-author rollups (behavioural grouping) join on user_id. */
CREATE NONCLUSTERED INDEX ix_posts_user
    ON dbo.posts (user_id)
    INCLUDE (posted_at, engagement, sentiment);
GO

/* Brand x sentiment cross-tabs. Filtered: ~15% of rows have no brand and
   they are never the subject of a brand query, so excluding them keeps
   the index materially smaller. */
CREATE NONCLUSTERED INDEX ix_posts_brand_sentiment
    ON dbo.posts (brand, sentiment)
    INCLUDE (engagement, platform)
    WHERE brand IS NOT NULL;
GO

/* Anomaly queries read only the flagged minority. */
CREATE NONCLUSTERED INDEX ix_posts_contradictory
    ON dbo.posts (is_contradictory)
    INCLUDE (platform, brand, sentiment, engagement)
    WHERE is_contradictory = 1;
GO

/* Correlation work always filters likes_imputed = 0. */
CREATE NONCLUSTERED INDEX ix_posts_observed_likes
    ON dbo.posts (likes_imputed)
    INCLUDE (likes, shares, comments, platform)
    WHERE likes_imputed = 0;
GO

/* Bridge table is traversed in both directions; the PK covers
   post -> tag, this covers tag -> post. */
CREATE NONCLUSTERED INDEX ix_ph_hashtag
    ON dbo.post_hashtags (hashtag_id, post_id);
GO

/* --------------------------------------------------------------------
   Integrity audit. Every row of this result set must read 0.
   This is the SQL-side mirror of src/validate.py - the Phase 1 contract
   is re-proved after the data crosses into the database, so a bad load
   cannot masquerade as a bad analysis.
   -------------------------------------------------------------------- */
SELECT 'duplicate post_id'              AS check_name,
       COUNT(*) - COUNT(DISTINCT post_id) AS violations FROM dbo.posts
UNION ALL
SELECT 'orphan user_id',
       COUNT(*) FROM dbo.posts p
       WHERE NOT EXISTS (SELECT 1 FROM dbo.users u WHERE u.user_id = p.user_id)
UNION ALL
SELECT 'negative engagement metric',
       COUNT(*) FROM dbo.posts WHERE likes < 0 OR shares < 0 OR comments < 0
UNION ALL
SELECT 'post predates account creation',
       COUNT(*) FROM dbo.posts p
       JOIN dbo.users u ON u.user_id = p.user_id
       WHERE p.posted_at < u.account_created
UNION ALL
SELECT 'timestamp outside corpus window',
       COUNT(*) FROM dbo.posts
       WHERE posted_at < '2024-05-01' OR posted_at >= '2025-05-01'
UNION ALL
SELECT 'markup or entity surviving in text',
       COUNT(*) FROM dbo.posts
       WHERE text_content LIKE '%<%>%' OR text_content LIKE '%&amp;%'
UNION ALL
SELECT 'null sentinel surviving in text',
       COUNT(*) FROM dbo.posts WHERE text_content IN ('NULL','null','nan','N/A')
UNION ALL
SELECT 'hashtag bridge orphan',
       COUNT(*) FROM dbo.post_hashtags ph
       WHERE NOT EXISTS (SELECT 1 FROM dbo.posts p WHERE p.post_id = ph.post_id);
GO

PRINT 'Indexes built, integrity audit complete.';
GO
