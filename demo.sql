-- =====================================================================
-- GlobalCard live demos: Query Evaluation & Optimization in PostgreSQL
-- CS3543 Group 19. Run setup.sql first.
--
-- Run one section at a time in psql (copy-paste) or the whole file:
--   psql -d globalcard -f demo.sql
--
-- Numbers in the comments come from test runs on PostgreSQL 16 (yours may
-- differ by a few units). Row
-- estimates wobble a little each time ANALYZE runs (it samples randomly).
-- Costs should match on any PG 16+ with default settings. Timings will
-- vary by laptop, so point at row counts and plan shapes, not seconds.
-- =====================================================================

SET jit = off;                -- keeps JIT noise out of the plans
\pset pager off


-- =====================================================================
-- SPEAKER 1: How the optimizer SEES the skew (statistics)
-- =====================================================================
\echo '\n===== SPEAKER 1: statistics and skew detection =====\n'

-- 1a. What ANALYZE stored about tx_purchase.merchant_id
--     Point at: Amazon (1) and Walmart (2) top the MCV list with ~12% and ~5%.
--     n_distinct ~ 32k is an ESTIMATE from a 30,000-row sample (true value is 50k).
SELECT n_distinct,
       (most_common_vals::text::bigint[])[1:5] AS top_mcv_merchants,
       most_common_freqs[1:5]                  AS their_frequencies,
       array_length(most_common_freqs, 1)      AS mcv_list_size,
       histogram_bounds IS NOT NULL            AS has_histogram
FROM pg_stats
WHERE tablename = 'tx_purchase' AND attname = 'merchant_id';

-- 1b. Same query, two merchants, two estimates
--     Amazon:  rows ~290,000 (straight from its MCV frequency x row count)
--     Shop:    rows ~54      (NOT from the histogram, see 1c)
EXPLAIN SELECT * FROM tx_purchase WHERE merchant_id = 1;      -- Amazon
EXPLAIN SELECT * FROM tx_purchase WHERE merchant_id = 4242;   -- Local Shop

-- 1c. Where the "54" comes from. For = on a value NOT in the MCV list,
--     Postgres spreads the leftover frequency evenly:
--        (1 - sum(MCV freqs) - null_frac) / (n_distinct - #MCVs) x rows
--     The histogram is only used for ranges (<, >, BETWEEN).
SELECT round((1 - s.mcv_total - s.null_frac)
             / (s.n_distinct - s.mcv_count)
             * c.reltuples) AS estimated_rows_for_small_shop
FROM (SELECT (SELECT sum(f) FROM unnest(most_common_freqs) f) AS mcv_total,
             array_length(most_common_freqs, 1)               AS mcv_count,
             null_frac, n_distinct
      FROM pg_stats
      WHERE tablename = 'tx_purchase' AND attname = 'merchant_id') s,
     pg_class c
WHERE c.relname = 'tx_purchase';

-- 1d. Different estimate -> different plan. Real numbers:
--     Shop:   Bitmap Heap Scan, Heap Blocks: exact=~44  (touches 44 pages)
--     Amazon: Bitmap Heap Scan, Heap Blocks: exact=27272 (the table has
--             27,273 pages, so it reads basically the WHOLE table, in
--             physical order). This is Postgres's middle ground between
--             an index scan and a seq scan. MySQL has no bitmap scan.
EXPLAIN ANALYZE SELECT * FROM tx_purchase WHERE merchant_id = 4242;
EXPLAIN ANALYZE SELECT * FROM tx_purchase WHERE merchant_id = 1;

-- 1e. Why not the alternatives for Amazon? Force them and compare cost:
--     Bitmap ~34,258  <  Seq Scan ~57,273  <  Index Scan ~115,237
--     The plain index scan is the "billions of random reads" plan.
SELECT relpages AS table_pages FROM pg_class WHERE relname = 'tx_purchase';
SET enable_bitmapscan = off;
EXPLAIN SELECT * FROM tx_purchase WHERE merchant_id = 1;   -- now Seq Scan
SET enable_seqscan = off;
EXPLAIN SELECT * FROM tx_purchase WHERE merchant_id = 1;   -- now Index Scan
RESET enable_bitmapscan;
RESET enable_seqscan;

-- Optional talking point: more detail for a skewed column
--   ALTER TABLE tx_purchase ALTER COLUMN merchant_id SET STATISTICS 1000;
--   ANALYZE tx_purchase;    -- bigger sample, longer MCV list


-- =====================================================================
-- SPEAKER 2: Bind variables / parameter sniffing, and forcing plans
-- =====================================================================
\echo '\n===== SPEAKER 2: parameter sniffing and plan control =====\n'

-- Turn off parallelism here only so the plans are short enough to read
SET max_parallel_workers_per_gather = 0;

-- 2a. A prepared statement = what the app does with a bind variable
--     "How much did merchant $1 sell?"
PREPARE merchant_total(bigint) AS
  SELECT count(*), sum(t.amount)
  FROM tx_purchase p
  JOIN "transaction" t ON t.transaction_id = p.transaction_id
  WHERE p.merchant_id = $1;

-- 2b. Custom plan for Amazon: knows the value is Amazon, so
--     Hash Join, rows ~290,000 (correct)
EXPLAIN EXECUTE merchant_total(1);

-- 2c. Reset, then simulate normal traffic: 5 runs, one of them a chain store
DEALLOCATE merchant_total;
PREPARE merchant_total(bigint) AS
  SELECT count(*), sum(t.amount)
  FROM tx_purchase p
  JOIN "transaction" t ON t.transaction_id = p.transaction_id
  WHERE p.merchant_id = $1;

EXECUTE merchant_total(4242);   -- small shop
EXECUTE merchant_total(3);      -- Costco (chain, ~1%)
EXECUTE merchant_total(4243);   -- small shop
EXECUTE merchant_total(4244);   -- small shop
EXECUTE merchant_total(4245);   -- small shop

-- 5 custom plans so far
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;

-- 2d. THE TRAP. Run #6, and it's Amazon. Postgres compares the generic
--     plan's cost to the AVERAGE custom-plan cost so far; the generic one
--     looks cheap enough, so it gets cached and reused.
--     Point at:  Recheck Cond: (merchant_id = $1)   <- generic plan
--                rows ~74 estimated vs actual rows=288,361
--                Nested Loop ... loops=288361 (288k index probes)
--     NOTE: on a laptop everything fits in RAM, so this may NOT run slower.
--     Say so: the cost model assumes disk (random_page_cost = 4). With 300B
--     rows on disk, each of those loops is a random disk read.
EXPLAIN ANALYZE EXECUTE merchant_total(1);
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;

-- (Fun fact for Q&A: if all 5 warm-up runs are small shops, Postgres
--  stays on custom plans, because they're cheaper than the generic one.)

-- 2e. FIX 1: plan_cache_mode (PG 12+). Re-plan with the real value every time.
SET plan_cache_mode = force_custom_plan;
EXPLAIN EXECUTE merchant_total(1);      -- back to Hash Join, rows ~290,000
SET plan_cache_mode = force_generic_plan;
EXPLAIN EXECUTE merchant_total(1);      -- the cached Nested Loop again
RESET plan_cache_mode;                  -- default = auto

-- 2f. See a generic plan without even preparing (PG 16+)
EXPLAIN (GENERIC_PLAN)
  SELECT * FROM tx_purchase WHERE merchant_id = $1;

-- 2g. FIX 2: enable_* switches. These aren't hints; they just make a plan
--     type look extremely expensive for this session.
SET enable_nestloop = off;
EXPLAIN EXECUTE merchant_total(1);
RESET enable_nestloop;

-- 2h. FIX 3: pg_hint_plan (third-party extension, NOT built in; Postgres
--     deliberately has no hints, stored outlines or plan guides). If installed:
--   LOAD 'pg_hint_plan';
--   /*+ HashJoin(p t) SeqScan(p) */
--   SELECT count(*), sum(t.amount) FROM tx_purchase p
--   JOIN "transaction" t ON t.transaction_id = p.transaction_id
--   WHERE p.merchant_id = 1;

DEALLOCATE merchant_total;
RESET max_parallel_workers_per_gather;


-- =====================================================================
-- SPEAKER 3: The large-scale join (top 10 merchant categories)
-- =====================================================================
\echo '\n===== SPEAKER 3: the large-scale join =====\n'

-- In the real GlobalCard schema, merchant_id lives on tx_purchase and
-- amount lives on transaction, so this is a 3-table join.

-- 3a. The likely plan. Read it bottom-up:
--     Parallel Seq Scan transaction  +  Parallel Seq Scan tx_purchase
--       -> Parallel Hash Join on transaction_id   (the BIG join: huge x huge,
--          hash built on tx_purchase)
--       -> Hash Join with merchant                 (the easy join)
--       -> Partial HashAggregate per worker -> Gather Merge
--       -> Finalize GroupAggregate -> Sort (top-N heapsort) -> Limit 10
--     Estimated total cost ~131,799
EXPLAIN
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code
ORDER BY volume DESC
LIMIT 10;

-- 3b. WHY hash join? Take it away and watch the cost:
--     hash join off  -> Merge Join on transaction_id (both PKs are already
--                       sorted indexes, so no sort needed) + Nested Loop
--                       with Memoize for merchant. Cost ~244,301 (~1.9x)
SET enable_hashjoin = off;
EXPLAIN
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code ORDER BY volume DESC LIMIT 10;

--     merge join off too -> Nested Loops: one index probe into
--                       transaction per purchase. Cost ~596,368 (~4.5x)
SET enable_mergejoin = off;
EXPLAIN
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code ORDER BY volume DESC LIMIT 10;

RESET enable_hashjoin;
RESET enable_mergejoin;

-- Key line: the planner doesn't compare Big-O. It compares these cost
-- numbers (built from seq_page_cost, random_page_cost, cpu_tuple_cost
-- and the row estimates) and picks the cheapest.


-- =====================================================================
-- SPEAKER 4: Memory - work_mem and spilling to disk
-- =====================================================================
\echo '\n===== SPEAKER 4: work_mem and disk spills =====\n'

SHOW work_mem;              -- 4MB default
SHOW hash_mem_multiplier;   -- 2 (default since PG 15) -> hash gets ~8MB

-- 4a. Tiny memory: watch "Batches" and "temp written"
--     Parallel Hash: Batches: 2048, Memory Usage: 128kB
--     Buffers: temp written=~57,000 blocks (~450MB of temp files)
--     Even the 50k-row merchant hash spills (Batches: 32). ~2.5x slower than 4c.
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code ORDER BY volume DESC LIMIT 10;

-- 4b. Default 4MB: Batches: 32, still spilling (temp written ~23,000 blocks)
RESET work_mem;
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code ORDER BY volume DESC LIMIT 10;

-- 4c. Enough memory: Batches: 1, no temp line at all, fastest run
--     Parallel Hash Memory Usage: ~145MB for 2.4M purchase rows
--     (~60 bytes/row). At 240B purchase rows that's ~14 TB, which is
--     why at GlobalCard scale this join WILL spill, whatever you set.
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.mcc_code, sum(t.amount) AS volume
FROM "transaction" t
JOIN tx_purchase p ON p.transaction_id = t.transaction_id
JOIN merchant m    ON m.merchant_id   = p.merchant_id
GROUP BY m.mcc_code ORDER BY volume DESC LIMIT 10;

-- 4d. Note the estimated cost also drops (131,799 at 4MB -> 109,825 at
--     256MB): the PLANNER prices in the batch I/O. That's how work_mem
--     influences the optimizer's choice, not just the runtime.
--     Gotcha: work_mem is per sort/hash node, per worker. Set it per
--     session for the report, never globally:
--       SET work_mem = '256MB';   -- this session only
RESET work_mem;

\echo '\nDone.\n'
