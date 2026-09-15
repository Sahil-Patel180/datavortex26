/* =====================================================================
   DATA VORTEX :: Round 1 Phase 2
   01 - Schema

   Design notes (this is the "schema design must be explained" deliverable)

   1. FOUR TABLES, NOT ONE. The cleaned CSV is a denormalised analysis
      frame. Loading it verbatim would embed user attributes in every post
      row (1,500 users repeated across 12,000 posts) and store hashtags as
      a delimited string, forcing LIKE '%tag%' scans. Split into:
         users          - one row per author
         posts          - one row per post, FK to users
         hashtags       - tag vocabulary (29 rows)
         post_hashtags  - many-to-many bridge (20,531 rows)

   2. PROVENANCE COLUMNS ARE FIRST CLASS. likes_imputed and
      ts_source_format are not debris from cleaning; they are filters that
      every honest aggregate needs. Imputed likes must be excluded from
      correlation work, and post_hour is only meaningful for rows whose
      source format carried a time component.

   3. CONSTRAINTS ENCODE THE DATA CONTRACT. The CHECK constraints mirror
      src/validate.py exactly. If a reload ever reintroduces a negative
      like count, the INSERT fails rather than the analysis silently
      changing.

   4. engagement IS COMPUTED AND PERSISTED. Storing it as a base column
      would let it drift out of sync with its inputs; recomputing it in
      every query costs a scan. PERSISTED gives correctness plus
      indexability.
   ===================================================================== */

USE DataVortex;
GO

/* --- drop in FK-safe order (idempotent re-run) ---------------------- */
DROP TABLE IF EXISTS dbo.post_hashtags;
DROP TABLE IF EXISTS dbo.hashtags;
DROP TABLE IF EXISTS dbo.posts;
DROP TABLE IF EXISTS dbo.users;
GO

/* ===================================================================== */
CREATE TABLE dbo.users
(
    user_id         VARCHAR(20)   NOT NULL,
    city            NVARCHAR(60)  NULL,
    country         NVARCHAR(60)  NULL,
    language        CHAR(2)       NULL,
    account_created DATE          NOT NULL,
    follower_count  INT           NOT NULL,

    CONSTRAINT pk_users            PRIMARY KEY (user_id),
    CONSTRAINT ck_users_followers  CHECK (follower_count >= 0),
    CONSTRAINT ck_users_created    CHECK (account_created >= '2023-01-01')
);
GO

/* ===================================================================== */
CREATE TABLE dbo.posts
(
    post_id            VARCHAR(20)   NOT NULL,
    user_id            VARCHAR(20)   NOT NULL,
    platform           VARCHAR(20)   NOT NULL,
    text_content       NVARCHAR(500) NULL,          -- NULL = missing in source
    posted_at          DATETIME2(0)  NOT NULL,
    ts_source_format   VARCHAR(16)   NOT NULL,      -- ingest provenance

    likes              INT           NOT NULL,
    likes_imputed      BIT           NOT NULL CONSTRAINT df_posts_imputed DEFAULT (0),
    shares             INT           NOT NULL,
    comments           INT           NOT NULL,

    sentiment          VARCHAR(10)   NULL,
    opener_polarity    SMALLINT      NULL,
    verdict_polarity   SMALLINT      NULL,
    is_contradictory   BIT           NOT NULL CONSTRAINT df_posts_contra DEFAULT (0),

    brand              VARCHAR(30)   NULL,
    product            VARCHAR(40)   NULL,
    hashtag_count      TINYINT       NULL,
    mention_count      TINYINT       NULL,
    char_length        SMALLINT      NULL,
    word_count         SMALLINT      NULL,

    /* derived, stored once, always consistent with its inputs */
    engagement AS (likes + shares + comments) PERSISTED,

    CONSTRAINT pk_posts           PRIMARY KEY (post_id),
    CONSTRAINT fk_posts_users     FOREIGN KEY (user_id) REFERENCES dbo.users (user_id),

    /* --- data contract, mirrored from src/validate.py --- */
    CONSTRAINT ck_posts_likes     CHECK (likes    BETWEEN 0 AND 5000),
    CONSTRAINT ck_posts_shares    CHECK (shares   BETWEEN 0 AND 2000),
    CONSTRAINT ck_posts_comments  CHECK (comments BETWEEN 0 AND 1000),
    CONSTRAINT ck_posts_window    CHECK (posted_at >= '2024-05-01' AND posted_at < '2025-05-01'),
    CONSTRAINT ck_posts_platform  CHECK (platform IN ('Facebook','Instagram','Reddit','Twitter','YouTube','Unknown')),
    CONSTRAINT ck_posts_tsfmt     CHECK (ts_source_format IN ('iso8601','unix_seconds','dd_mm_yyyy')),
    CONSTRAINT ck_posts_sentiment CHECK (sentiment IS NULL OR sentiment IN ('positive','neutral','negative')),
    CONSTRAINT ck_posts_polarity  CHECK (
           (opener_polarity  IS NULL OR opener_polarity  BETWEEN -1 AND 1)
       AND (verdict_polarity IS NULL OR verdict_polarity BETWEEN -1 AND 1))
);
GO

/* ===================================================================== */
CREATE TABLE dbo.hashtags
(
    hashtag_id INT         NOT NULL,
    tag        VARCHAR(50) NOT NULL,

    CONSTRAINT pk_hashtags  PRIMARY KEY (hashtag_id),
    CONSTRAINT uq_hashtags  UNIQUE (tag)
);
GO

CREATE TABLE dbo.post_hashtags
(
    post_id    VARCHAR(20) NOT NULL,
    hashtag_id INT         NOT NULL,

    CONSTRAINT pk_post_hashtags PRIMARY KEY (post_id, hashtag_id),
    CONSTRAINT fk_ph_post       FOREIGN KEY (post_id)    REFERENCES dbo.posts (post_id),
    CONSTRAINT fk_ph_hashtag    FOREIGN KEY (hashtag_id) REFERENCES dbo.hashtags (hashtag_id)
);
GO

PRINT 'Schema created.';
GO
