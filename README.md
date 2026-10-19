# CS3543 Group 19: GlobalCard on PostgreSQL

Demo database and queries for our lecture on **Query Evaluation & Optimization in PostgreSQL** (CS3543, UNB, Fall 2026).

It builds a small, deliberately skewed copy of the GlobalCard case-study schema. Then it runs the `EXPLAIN` demos for both GlobalCard problems:

- **Problem A: Holiday Skew.** Statistics, MCV lists, parameter sniffing, and plan control.
- **Problem B: Large-Scale Join.** Join method choice, `work_mem`, and spilling to disk.

| File | What it does |
|---|---|
| `setup.sql` | Creates `merchant`, `transaction` and `tx_purchase` and loads skewed data: 50k merchants, 3M transactions, ~2.4M purchases. Amazon is ~12% of purchases and Walmart ~5%. Takes about 1 minute. |
| `demo.sql` | One section per speaker. Every query is commented with what to look for. |

The data uses a fixed random seed, so **everyone gets identical rows**.

## Run it on Windows (PostgreSQL installed)

1. Install PostgreSQL 16+ with the [EDB installer](https://www.postgresql.org/download/windows/). Remember the password you set.
2. Download this repo: **Code → Download ZIP**, then unzip it.
3. Open **SQL Shell (psql)** from the Start menu. Press Enter for the server, database, port and username prompts, then type your password.
4. Run:
   ```
   CREATE DATABASE globalcard;
   \c globalcard
   \i 'C:/Users/<you>/Downloads/cs3543-group19-postgres-demo-main/setup.sql'
   ```
   Use **forward slashes** in the path. psql treats `\` as a special character.
5. When you see the Amazon ~12% / Walmart ~5% table, setup is done. You only do this once.
6. For the demos, open `demo.sql` in an editor and paste your section at the `globalcard=#` prompt. Or run the whole file:
   ```
   \i 'C:/Users/<you>/Downloads/cs3543-group19-postgres-demo-main/demo.sql'
   ```

Next time, open SQL Shell and type `\c globalcard`. The database stays on your laptop.

## Run it on Mac / Linux

```bash
createdb globalcard
psql -d globalcard -f setup.sql
psql -d globalcard            # then paste sections from demo.sql
```

## Run it with Docker (no install needed)

```bash
docker run --name pgdemo -e POSTGRES_PASSWORD=pg -p 5432:5432 --shm-size=1g -d postgres:16
docker exec pgdemo psql -U postgres -c "CREATE DATABASE globalcard"
docker exec -i pgdemo psql -U postgres -d globalcard < setup.sql
docker exec -it pgdemo psql -U postgres -d globalcard
```

Keep `--shm-size=1g`. Docker's default shared memory is too small for the parallel hash join demo.

## What each section shows

| Speaker | Demo | Look for |
|---|---|---|
| 1. Statistics | `pg_stats` MCV list; Amazon vs a small shop | Amazon's estimate comes from its MCV frequency. A small shop's estimate comes from the leftover frequency, not the histogram. |
| 2. Sniffing and forcing | Prepared statement, 5 warm-up runs, then Amazon | The generic plan (`$1`) estimates ~74 rows and gets 288,361, so it picks a Nested Loop instead of a Hash Join. Fixed with `plan_cache_mode`. |
| 3. Big join | Top 10 MCC report, then `enable_hashjoin` / `enable_mergejoin` off | Two hash joins. The cost goes ~131.8k (hash) → ~244.6k (merge) → ~596.7k (nested loop). |
| 4. Memory | Same report at `work_mem` 64kB / 4MB / 256MB | Batches go 2048 → 32 → 1, and the temp files disappear. |

## Notes

- **Costs can differ slightly between laptops** (e.g. 131,801 vs 131,799), because `ANALYZE` uses a random sample. Plan shapes are the same.
- Everything fits in RAM on a laptop, so a "bad" plan may not run slower here. Compare estimated vs actual rows and costs, not milliseconds.
- PostgreSQL doesn't auto-index foreign keys. `setup.sql` creates `ix_tx_purchase_merchant` explicitly.

## Sources

- [Using EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)
- [Statistics used by the planner](https://www.postgresql.org/docs/current/planner-stats.html) and [row estimation examples](https://www.postgresql.org/docs/current/row-estimation-examples.html)
- [PREPARE / plan caching](https://www.postgresql.org/docs/current/sql-prepare.html)
- [Query planning settings](https://www.postgresql.org/docs/current/runtime-config-query.html)
- [Resource consumption (`work_mem`, `hash_mem_multiplier`)](https://www.postgresql.org/docs/current/runtime-config-resource.html)
- [Parallel plans](https://www.postgresql.org/docs/current/parallel-plans.html)
- GlobalCard schema: CS3543 case study, A. McAllister
