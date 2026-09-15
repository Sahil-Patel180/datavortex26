USE DataVortex;
GO
/* M5 - Detect Suspicious Engagement
 The final dbo.posts table does not store shares_exceed_likes as a
 persisted column; that flag exists in the cleaned/staging data.
 Evaluate the questionnaire condition directly from base metrics. */
SELECT TOP (20)
 post_id,
 platform,
 likes,
 shares,
 comments,
 engagement
FROM dbo.posts
WHERE shares > likes + comments
ORDER BY engagement DESC, post_id ASC;
GO