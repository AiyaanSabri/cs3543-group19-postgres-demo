-- =====================================================================
-- GlobalCard demo database for PostgreSQL (CS3543, Group 19)
-- Query Evaluation & Optimization: PostgreSQL
--
-- Tables mirror the course GlobalCard schema (merchant, transaction,
-- tx_purchase), trimmed to the columns the demos need. FKs to tables
-- we don't build (account, card, party) are left out.
--
-- Data is deliberately SKEWED:
--   merchant 1  = "Amazon"   ~12% of all purchases
--   merchant 2  = "Walmart"  ~5%
--   merchants 3-12 = big chains, ~1% each
--   merchants 13-50000 = small shops, ~35 purchases each
--
-- Size: 50k merchants, 3M transactions, ~2.4M purchases (~1 min to build)
-- Run:  psql -d globalcard -f setup.sql
-- =====================================================================

SET client_min_messages = warning;

DROP TABLE IF EXISTS tx_purchase;
DROP TABLE IF EXISTS "transaction";
DROP TABLE IF EXISTS merchant;

-- ---------------------------------------------------------------------
-- MERCHANT  (production: tens of millions of rows)
-- ---------------------------------------------------------------------
CREATE TABLE merchant (
    merchant_id  BIGINT       PRIMARY KEY,
    legal_name   VARCHAR(150) NOT NULL,
    mcc_code     CHAR(4)      NOT NULL,          -- Merchant Category Code
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- TRANSACTION  (production: 300B rows, 40B+ new per year)
-- ---------------------------------------------------------------------
CREATE TABLE "transaction" (
    transaction_id    BIGINT        PRIMARY KEY,
    account_id        BIGINT        NOT NULL,
    transaction_type  VARCHAR(20)   NOT NULL,
    amount            DECIMAL(15,2) NOT NULL,
    transaction_date  TIMESTAMP     NOT NULL,
    posted_date       TIMESTAMP     NOT NULL,
    description       VARCHAR(255)  NOT NULL,
    is_disputed       BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_transaction_type CHECK (transaction_type IN
        ('PURCHASE','CASH_ADVANCE','FEE','INTEREST_CHARGE',
         'PAYMENT','REFUND','ADJUSTMENT'))
);

-- ---------------------------------------------------------------------
-- TX_PURCHASE  (subtype of transaction; this is where merchant_id lives)
-- ---------------------------------------------------------------------
CREATE TABLE tx_purchase (
    transaction_id    BIGINT      PRIMARY KEY REFERENCES "transaction",
    transaction_type  VARCHAR(20) NOT NULL DEFAULT 'PURCHASE'
                      CHECK (transaction_type = 'PURCHASE'),
    account_id        BIGINT      NOT NULL,
    card_id           BIGINT      NOT NULL,
    merchant_id       BIGINT      NOT NULL REFERENCES merchant,
    terminal_id       VARCHAR(50),
    auth_code         CHAR(6)     NOT NULL,
    is_recurring      BOOLEAN     NOT NULL DEFAULT FALSE
);

-- ---------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------
SELECT setseed(0.42);   -- same data on every laptop

INSERT INTO merchant (merchant_id, legal_name, mcc_code)
SELECT g,
       CASE g WHEN 1 THEN 'Amazon'
              WHEN 2 THEN 'Walmart'
              WHEN 3 THEN 'Costco'
              WHEN 4 THEN 'Target'
              WHEN 5 THEN 'Best Buy'
              WHEN 6 THEN 'Home Depot'
              WHEN 7 THEN 'Starbucks'
              WHEN 8 THEN 'Shell'
              WHEN 9 THEN 'Uber'
              WHEN 10 THEN 'Apple'
              WHEN 11 THEN 'Netflix'
              WHEN 12 THEN 'Tim Hortons'
              ELSE 'Local Shop #' || g END,
       (ARRAY['5411','5311','5732','5812','5814','5541','4121','5942',
              '5999','5691','5651','5200','5912','7832','4899','5300',
              '5399','5945','5977','7230','7298','8011','8021','8099',
              '5122','5655','5661','5712','5722','5734','5811','5813',
              '5921','5940','5941','5943','5947','5992','5993','5995'])
              [1 + (hashint4(g::int) & 2147483647) % 40]
FROM generate_series(1, 50000) g;

-- 3M transactions; 80% are purchases
INSERT INTO "transaction"
SELECT g,
       1 + (random() * 999999)::bigint,
       CASE WHEN g % 10 < 8 THEN 'PURCHASE'
            WHEN g % 10 = 8 THEN 'PAYMENT' ELSE 'FEE' END,
       round((5 + random() * 495)::numeric, 2),
       ts, ts + interval '1 day',
       'txn ' || g,
       random() < 0.0005
FROM generate_series(1, 3000000) g,
     LATERAL (SELECT timestamp '2025-01-01'
                     + random() * interval '364 days' AS ts) t;

-- Skewed merchant assignment for purchases
INSERT INTO tx_purchase (transaction_id, account_id, card_id,
                         merchant_id, terminal_id, auth_code, is_recurring)
SELECT t.transaction_id, t.account_id, t.account_id * 2,
       CASE WHEN r < 0.12 THEN 1                               -- Amazon
            WHEN r < 0.17 THEN 2                               -- Walmart
            WHEN r < 0.27 THEN 3 + ((r - 0.17) * 100)::int % 10 -- chains
            ELSE 13 + (random() * 49987)::bigint                -- small shops
       END,
       'T' || (t.transaction_id % 9999),
       lpad((t.transaction_id % 999999)::text, 6, '0'),
       false
FROM "transaction" t,
     LATERAL (SELECT random() + t.transaction_id * 0 AS r) x
WHERE t.transaction_type = 'PURCHASE';

-- PostgreSQL does NOT auto-create indexes on foreign-key columns
-- (MySQL/InnoDB does). Without this, Holiday Skew has no index to flip to.
CREATE INDEX ix_tx_purchase_merchant ON tx_purchase (merchant_id);

-- Collect statistics (fills pg_statistic / pg_stats)
VACUUM ANALYZE merchant;
VACUUM ANALYZE "transaction";
VACUUM ANALYZE tx_purchase;

-- Quick sanity check
SELECT m.legal_name, count(*) AS purchases,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM tx_purchase p JOIN merchant m USING (merchant_id)
GROUP BY m.legal_name
ORDER BY purchases DESC
LIMIT 5;
