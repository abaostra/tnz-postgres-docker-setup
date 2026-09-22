-- =====================================================================
--  Postgres Intro KT  ·  Step 2  ·  Data load  ·  LARGE scale
--  ---------------------------------------------------------------
--  Populates the shop schema (customers + orders) with enough volume to
--  actually SEE index and bloat effects: ~2,000 customers and ~50,000
--  orders. At this size a sequential scan is measurably slower than an
--  index scan, and a bulk status UPDATE leaves a visible trail of dead
--  tuples — the small load is too tiny for either to show.
--
--  Identical logic to load_small.sql — ONLY the two row counts differ
--  (500 -> 2000 customers, 5000 -> 50000 orders). Same properties:
--    * REPRODUCIBLE   — setseed() fixes the random stream.
--    * IDEMPOTENT     — TRUNCATE ... RESTART IDENTITY CASCADE first.
--    * SELF-VERIFYING — prints counts, date range and status mix.
--
--  Run it (after 01_shop_schema.sql has built the objects):
--      psql -d shop -f load_large.sql
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

-- Force a single worker so the seeded random() sequence is perfectly
-- reproducible (parallel workers keep separate random-number state).
SET max_parallel_workers_per_gather = 0;

-- Fix the pseudo-random seed. Any run with this seed yields the same data.
SELECT setseed(0.42);

-- Idempotency: empty both tables and reset their IDENTITY counters to 1.
--   TRUNCATE          - fast, whole-table wipe (no per-row work, no bloat)
--   RESTART IDENTITY  - reset customer_id / order_id back to 1
--   CASCADE           - also truncate anything that references these tables
--                       (orders references customers; future child tables too)
TRUNCATE orders, customers RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- CUSTOMERS  (~2,000 rows)  - the dimension
-- generate_series(1, 2000) emits the numbers 1..2000 -> one row each.
-- The LATERAL subquery rolls the country ONCE so the city can match it.
-- ---------------------------------------------------------------------
INSERT INTO customers (full_name, email, country, city, segment)
WITH picks AS (
    SELECT
        g,
        -- Generate random country per row inside the CTE
        (ARRAY['IN','IN','IN','US','US','UK','SG','AE'])[1+floor(random()*8)::int] AS country
    FROM generate_series(1, 2000) AS g
)
SELECT
    'Customer ' || g,
    'cust' || g || '@example.com',
    country,
    CASE country
        WHEN 'IN' THEN (ARRAY['Bengaluru','Mumbai','Delhi','Hyderabad'])[1+floor(random()*4)::int]
        WHEN 'US' THEN (ARRAY['New York','San Francisco','Austin'])[1+floor(random()*3)::int]
        WHEN 'UK' THEN 'London'
        WHEN 'SG' THEN 'Singapore'
        ELSE           'Dubai'
    END,
    (ARRAY['Retail','Retail','Retail','Retail','Wholesale','Prime'])[1+floor(random()*6)::int]
FROM picks;

-- ---------------------------------------------------------------------
-- ORDERS  (~50,000 rows)  - the fact
-- Each order points at a random existing customer and lands on a random
-- day across ~9 months. order_amount is rolled in a LATERAL so the
-- discount can be computed as a fraction of it.
-- ---------------------------------------------------------------------
INSERT INTO orders (customer_id, order_ts, status, channel, payment_method,
                    item_count, order_amount, discount_amount)
WITH ncust AS (
    SELECT count(*)::int AS n FROM customers
),
amounts AS (
    SELECT
        g,
        -- Generate random order amount per row inside the CTE
        round((200 + random()*4800)::numeric, 2) AS order_amount
    FROM generate_series(1, 50000) AS g
)
SELECT
    1 + floor(random() * ncust.n)::int,
    timestamptz '2025-01-01' + (random() * interval '270 days'),
    (ARRAY['Delivered','Delivered','Delivered','Delivered','Delivered',
           'Delivered','Delivered','Delivered','Delivered',
           'Shipped','Shipped','Shipped',
           'Paid','Paid','Paid',
           'Placed','Placed',
           'Cancelled','Cancelled',
           'Returned'])[1+floor(random()*20)::int],
    (ARRAY['Web','Web','Web','Mobile','Mobile','Store'])[1+floor(random()*6)::int],
    (ARRAY['Card','Card','Card','UPI','UPI','UPI','NetBanking','COD'])[1+floor(random()*8)::int],
    1 + floor(random()*5)::int,
    amt.order_amount,
    CASE WHEN random() < 0.25
         THEN round((amt.order_amount * (0.05 + random()*0.15))::numeric, 2)
         ELSE 0
    END
FROM amounts amt
CROSS JOIN ncust;

-- ---------------------------------------------------------------------
-- SELF-VERIFICATION  - confirm the load looks right
-- ---------------------------------------------------------------------
\echo ''
\echo '================  LOAD COMPLETE - verification  ================'
\echo '--- row counts ---'
SELECT 'customers' AS table_name, count(*) AS rows FROM customers
UNION ALL
SELECT 'orders', count(*) FROM orders;

\echo '--- order date range (should span ~Jan..Sep 2025) ---'
SELECT min(order_ts)::date AS first_order, max(order_ts)::date AS last_order FROM orders;

\echo '--- status funnel (Cancelled/Returned are excluded from the sales views) ---'
SELECT status,
       count(*) AS orders,
       round(100.0*count(*)/sum(count(*)) OVER (), 1) AS pct
FROM orders
GROUP BY status
ORDER BY orders DESC;
