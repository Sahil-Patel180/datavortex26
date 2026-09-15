/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   02 - Load

   BULK INSERT, not the SSMS Import Flat File wizard. The wizard is a
   point-and-click sequence that cannot be committed, reviewed or re-run;
   it also guesses VARCHAR(50) for text_content and silently truncates.
   This script is the reproducible workflow the rulebook asks for.

   CODEPAGE = '65001' is MANDATORY. Without it SQL Server reads the UTF-8
   files as the server codepage and reintroduces exactly the mojibake that
   Phase 1 spent a rule removing.

   Adjust @root to wherever the repo sits on the machine running SSMS.
   The path must be readable BY THE SQL SERVER SERVICE ACCOUNT, not by
   your Windows login - a local SQL Server instance reading from a folder
   under C:\ is the simplest arrangement.
   ===================================================================== */

USE DataVortex;
GO

/* --------------------------------------------------------------------
   Staging tables: every column VARCHAR. Landing raw text first means a
   type mismatch surfaces as a reviewable row, not as a failed bulk load
   with an unhelpful line number.
   -------------------------------------------------------------------- */
DROP TABLE IF EXISTS stg.users;
DROP TABLE IF EXISTS stg.posts;
DROP TABLE IF EXISTS stg.hashtags;
DROP TABLE IF EXISTS stg.post_hashtags;
GO

CREATE TABLE stg.users
(
    user_id VARCHAR(50), city NVARCHAR(100), country NVARCHAR(100),
    language VARCHAR(10), account_created VARCHAR(30), follower_count VARCHAR(20)
);

CREATE TABLE stg.posts
(
    post_id VARCHAR(50), user_id VARCHAR(50), platform VARCHAR(50),
    text_content NVARCHAR(1000), posted_at VARCHAR(30), ts_source_format VARCHAR(30),
    likes VARCHAR(20), likes_imputed VARCHAR(10), shares VARCHAR(20), comments VARCHAR(20),
    engagement VARCHAR(20), engagement_rate VARCHAR(40), sentiment VARCHAR(20),
    opener_polarity VARCHAR(10), verdict_polarity VARCHAR(10), is_contradictory VARCHAR(10),
    brand VARCHAR(50), product VARCHAR(60), hashtag_count VARCHAR(10),
    mention_count VARCHAR(10), char_length VARCHAR(10), word_count VARCHAR(10),
    post_date VARCHAR(30), post_month VARCHAR(10), post_hour VARCHAR(10),
    post_dow VARCHAR(20), is_weekend VARCHAR(10), engagement_z VARCHAR(40),
    is_engagement_outlier VARCHAR(10), shares_exceed_likes VARCHAR(10),
    anomaly_flags VARCHAR(200), is_anomalous VARCHAR(10)
);

CREATE TABLE stg.hashtags      (hashtag_id VARCHAR(20), tag VARCHAR(100));
CREATE TABLE stg.post_hashtags (post_id VARCHAR(50), hashtag_id VARCHAR(20));
GO

/* --------------------------------------------------------------------
   Bulk load.
   FORMAT='CSV' + FIELDQUOTE='"' handles the quoted text_content fields
   that contain commas. ROWTERMINATOR='0x0a' matches the LF line endings
   written by the Python pipeline on any OS.
   -------------------------------------------------------------------- */
DECLARE @root NVARCHAR(260) = N'C:\dv\';
DECLARE @sql  NVARCHAR(MAX);

SET @sql = N'
BULK INSERT stg.users FROM ''' + @root + N'users_clean.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0d0a'', CODEPAGE=''65001'', TABLOCK);

BULK INSERT stg.posts FROM ''' + @root + N'posts_clean.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0d0a'', CODEPAGE=''65001'', TABLOCK);

BULK INSERT stg.hashtags FROM ''' + @root + N'hashtags.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0d0a'', CODEPAGE=''65001'', TABLOCK);

BULK INSERT stg.post_hashtags FROM ''' + @root + N'post_hashtags.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0d0a'', CODEPAGE=''65001'', TABLOCK);';

EXEC sp_executesql @sql;
GO

/* --------------------------------------------------------------------
   Typed insert, parents before children.
   TRY_CAST rather than CAST: a bad value lands as NULL and is caught by
   the verification block below, instead of aborting the batch.
   -------------------------------------------------------------------- */
INSERT INTO dbo.users (user_id, city, country, language, account_created, follower_count)
SELECT user_id,
       NULLIF(city, ''),
       NULLIF(country, ''),
       NULLIF(language, ''),
       TRY_CAST(account_created AS DATE),
       TRY_CAST(follower_count AS INT)
FROM stg.users;
GO

INSERT INTO dbo.posts
(
    post_id, user_id, platform, text_content, posted_at, ts_source_format,
    likes, likes_imputed, shares, comments,
    sentiment, opener_polarity, verdict_polarity, is_contradictory,
    brand, product, hashtag_count, mention_count, char_length, word_count
)
SELECT post_id, user_id, platform,
       NULLIF(text_content, ''),
       TRY_CAST(posted_at AS DATETIME2(0)),
       ts_source_format,
       TRY_CAST(likes AS INT),
       CASE WHEN likes_imputed    IN ('True','true','1') THEN 1 ELSE 0 END,
       TRY_CAST(shares AS INT),
       TRY_CAST(comments AS INT),
       NULLIF(sentiment, ''),
       TRY_CAST(NULLIF(opener_polarity , '') AS SMALLINT),
       TRY_CAST(NULLIF(verdict_polarity, '') AS SMALLINT),
       CASE WHEN is_contradictory IN ('True','true','1') THEN 1 ELSE 0 END,
       NULLIF(brand, ''),
       NULLIF(product, ''),
       TRY_CAST(NULLIF(hashtag_count, '') AS TINYINT),
       TRY_CAST(NULLIF(mention_count, '') AS TINYINT),
       TRY_CAST(NULLIF(char_length  , '') AS SMALLINT),
       TRY_CAST(NULLIF(word_count   , '') AS SMALLINT)
FROM stg.posts;
GO

INSERT INTO dbo.hashtags (hashtag_id, tag)
SELECT TRY_CAST(hashtag_id AS INT), tag FROM stg.hashtags;
GO

INSERT INTO dbo.post_hashtags (post_id, hashtag_id)
SELECT post_id, TRY_CAST(hashtag_id AS INT) FROM stg.post_hashtags;
GO

/* --------------------------------------------------------------------
   Load verification. Expected: 12000 / 1500 / 29 / 20531, zero nulls in
   any NOT NULL-intent column. Screenshot this for the Phase 2 report.
   -------------------------------------------------------------------- */
SELECT 'users' AS table_name, COUNT(*) AS row_count, 1500  AS expected FROM dbo.users
UNION ALL SELECT 'posts',         COUNT(*), 12000 FROM dbo.posts
UNION ALL SELECT 'hashtags',      COUNT(*), 29    FROM dbo.hashtags
UNION ALL SELECT 'post_hashtags', COUNT(*), 20531 FROM dbo.post_hashtags;
GO

SELECT
    SUM(CASE WHEN posted_at IS NULL THEN 1 ELSE 0 END) AS null_posted_at,
    SUM(CASE WHEN likes     IS NULL THEN 1 ELSE 0 END) AS null_likes,
    SUM(CASE WHEN shares    IS NULL THEN 1 ELSE 0 END) AS null_shares,
    SUM(CASE WHEN comments  IS NULL THEN 1 ELSE 0 END) AS null_comments,
    MIN(posted_at) AS earliest_post,
    MAX(posted_at) AS latest_post
FROM dbo.posts;
GO

PRINT 'Load complete.';
GO
