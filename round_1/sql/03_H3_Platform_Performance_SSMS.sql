USE DataVortex;
GO
/* H3 - Platform Performance Compared With Its Own Average
 Compute each platform's average engagement with a window function,
 then keep posts at or above 2x that platform-specific average. */
WITH scored_posts AS
(
 SELECT
 p.post_id,
 p.user_id,
 p.platform,
 p.likes,
 p.shares,
 p.comments,
 p.engagement,
 AVG(CAST(p.engagement AS FLOAT))
 OVER (PARTITION BY p.platform) AS platform_avg_engagement
 FROM dbo.posts AS p
)
SELECT
 post_id,
 user_id,
 platform,
 likes,
 shares,
 comments,
 engagement,
 CAST(platform_avg_engagement AS DECIMAL(10,2))
 AS platform_avg_engagement,
 CAST(2 * platform_avg_engagement AS DECIMAL(10,2))
 AS exceptional_threshold
FROM scored_posts
WHERE engagement >= 2 * platform_avg_engagement
ORDER BY platform ASC, engagement DESC, post_id ASC;
GO