USE DataVortex;
GO
/* E1 - Platform Popularity
 Unknown represents missing platform values in the cleaned dataset.
 Exclude it before counting. */
SELECT TOP (1)
 platform,
 COUNT(*) AS post_count
FROM dbo.posts
WHERE platform <> 'Unknown'
GROUP BY platform
ORDER BY COUNT(*) DESC, platform ASC;
GO