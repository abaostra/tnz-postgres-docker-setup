-- =====================================================================
--  Postgres Intro KT  ·  Step 1  ·  The `shop` demo database
--  ---------------------------------------------------------------
--  Two-table e-commerce model: customers (dimension) + orders (fact),
--  plus two BI views, all created in a dedicated `sales` schema. This is
--  the PRE-LOADED demo DB the whole program runs on. 
--
--  Target : PostgreSQL 15+ (Tanzu Postgres 15.x). Validated on PG 16.15.
--  Run as : a login role that may create the objects (owner/superuser).
--
--  POSTGRES OBJECT HIERARCHY (what lives inside what):
--      cluster (the server)  ->  database  ->  schema  ->  tables / views
--  CREATE DATABASE and CREATE SCHEMA are NOT the same thing:
--    * CREATE DATABASE shop  makes a whole new database (the container).
--    * CREATE SCHEMA sales   makes a namespace INSIDE a database — and a
--                            schema is what actually holds tables.
--  Every database is born with a built-in schema called "public", so
--  unqualified objects land there by default. We instead put the demo in
--  a dedicated "sales" schema (cleaner than piling data into public) and
--  point the search_path at it, so you can still write plain `customers`
--  rather than `sales.customers` everywhere.
--
--  ONE-TIME SETUP (run these two lines interactively in psql first):
--      CREATE DATABASE shop;   -- cluster level: make the database (container)
--      \c shop                 -- \c = "connect": switch this psql session
--                              --      into the shop database
--  Then run this file against shop (it creates the sales schema itself):
--      psql -d shop -f 01_shop_schema.sql
-- =====================================================================

-- psql setting: abort the script on the first error instead of ploughing
-- on. Safer for labs. NB: a psql meta-command (\set, \c, \echo ...) takes
-- the WHOLE rest of its line as its argument, so an inline -- comment on
-- the same line would become part of the value. Keep such comments above.
\set ON_ERROR_STOP on

-- Create the dedicated schema and make it the default namespace.
--   CREATE SCHEMA           - a namespace INSIDE this database to hold our objects
--   ALTER DATABASE ... SET   - persists the search_path for EVERY future session
--                             that connects to shop (psql, the load scripts, the app)
--   SET search_path          - applies it to THIS session too, so the objects below
--                             are created in sales (ALTER DATABASE only takes effect
--                             for NEW sessions). "sales, public" = look in sales
--                             first, then public — so extensions that install into
--                             public still resolve.
--   NB: the database name in ALTER DATABASE is a literal — change it if your
--   database is not called shop.
CREATE SCHEMA IF NOT EXISTS sales;
ALTER DATABASE shop SET search_path = sales, public;
SET search_path = sales, public;

-- Clean rebuild: drop dependents first (views depend on the tables,
-- orders depends on customers). CASCADE would also work but being
-- explicit is clearer for teaching. IF EXISTS = no error if absent.
DROP VIEW  IF EXISTS v_customer_ltv;
DROP VIEW  IF EXISTS v_monthly_sales;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

-- ---------------------------------------------------------------------
-- DIMENSION: one row per customer ("who is buying")
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    -- bigint auto-key. GENERATED ALWAYS AS IDENTITY = the DB fills this
    -- from an internal sequence; ALWAYS means the app may not override
    -- it. PRIMARY KEY = unique + not-null + auto-creates a B-Tree index.
    customer_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    full_name        text NOT NULL,                 -- text: unbounded string
    email            text UNIQUE NOT NULL,          -- UNIQUE => its own index
    country          text NOT NULL,
    city             text,                           -- nullable: may be unknown
    segment          text NOT NULL DEFAULT 'Retail'  -- DEFAULT if unspecified
                       -- CHECK: a business rule enforced by the DB itself,
                       -- not just the app. Rejects any other value.
                       CHECK (segment IN ('Retail','Wholesale','Prime')),
    signed_up_on     date NOT NULL DEFAULT CURRENT_DATE,   -- date only
    marketing_opt_in boolean NOT NULL DEFAULT true          -- true/false
);

-- ---------------------------------------------------------------------
-- FACT: many rows per customer ("what was bought, when")
-- order_ts is a genuine time-ordered column -> drives the BRIN vs B-Tree
-- demo (S2) and every monthly-trend chart.
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- FOREIGN KEY: guarantees this points at a real customers row.
    -- You cannot insert an order for a customer that doesn't exist,
    -- and (by default) cannot delete a customer who still has orders.
    customer_id     bigint NOT NULL REFERENCES customers(customer_id),

    order_ts        timestamptz NOT NULL DEFAULT now(),  -- a real moment in
                                                         -- time (UTC-aware)
    -- The status lifecycle. Because an order moves Placed -> Paid ->
    -- Shipped -> Delivered over its life, rows get UPDATEd repeatedly —
    -- our realistic source of dead tuples / bloat in the S3 lab.
    status          text NOT NULL DEFAULT 'Placed'
                      CHECK (status IN ('Placed','Paid','Shipped',
                                        'Delivered','Cancelled','Returned')),
    channel         text NOT NULL
                      CHECK (channel IN ('Web','Mobile','Store')),
    payment_method  text NOT NULL
                      CHECK (payment_method IN ('Card','UPI',
                                                'NetBanking','COD')),
    item_count      int  NOT NULL CHECK (item_count > 0),

    -- numeric(10,2) = EXACT decimal, up to 10 digits, 2 after the point.
    -- Use for money — it never rounds the way float (double precision) does.
    order_amount    numeric(10,2) NOT NULL CHECK (order_amount >= 0),
    discount_amount numeric(10,2) NOT NULL DEFAULT 0
);

-- NOTE — indexes are DELIBERATELY minimal. The only indexes now are the
-- two PRIMARY KEYs and the UNIQUE(email), all auto-created. We do NOT add
-- an index on orders(customer_id) or a BRIN on order_ts here, because the
-- whole point of the Block 6 / S2 labs is to watch the plan flip from a
-- sequential scan to an index scan AFTER the attendee creates the index.

-- ---------------------------------------------------------------------
-- BI VIEWS  ·  a VIEW is a saved SELECT (a named query), not stored data.
-- Query it like a table; Postgres runs the underlying SELECT each time.
-- ---------------------------------------------------------------------

-- Monthly sales, split by channel — the classic dashboard feed.
CREATE VIEW v_monthly_sales AS
SELECT date_trunc('month', order_ts)::date        AS sales_month, -- bucket to 1st of month
       channel,
       count(*)                                    AS orders,
       sum(order_amount)                           AS gross_revenue,
       sum(discount_amount)                        AS total_discount,
       sum(order_amount - discount_amount)         AS net_revenue,
       round(avg(order_amount), 2)                 AS avg_order_value
FROM   orders
WHERE  status NOT IN ('Cancelled','Returned')      -- exclude non-sales
GROUP  BY 1, 2;   -- 1,2 = group by the 1st & 2nd SELECT items (sales_month, channel)

-- Customer lifetime value — dimension LEFT JOINed to fact so that even
-- customers with zero (qualifying) orders still appear, with 0 spend.
CREATE VIEW v_customer_ltv AS
SELECT c.customer_id, c.full_name, c.country, c.segment,
       count(o.order_id)                           AS lifetime_orders,
       coalesce(sum(o.order_amount), 0)            AS lifetime_spend, -- NULL -> 0
       max(o.order_ts)                             AS last_order_ts
FROM   customers c
LEFT   JOIN orders o
         ON o.customer_id = c.customer_id
        AND o.status NOT IN ('Cancelled','Returned')
GROUP  BY c.customer_id, c.full_name, c.country, c.segment;

-- Confirmation banner (\echo prints text from a psql script)
\echo '>> sales schema created in shop: customers, orders, v_monthly_sales, v_customer_ltv'
\echo '--- proof the objects live in the sales schema (not public) ---'
SELECT schemaname, tablename FROM pg_tables  WHERE tablename IN ('customers','orders')
UNION ALL
SELECT schemaname, viewname  FROM pg_views   WHERE viewname  LIKE 'v\_%'
ORDER BY 2;
\echo '--- default search_path now persisted on the shop database ---'
SELECT datname, (SELECT setting FROM pg_settings WHERE name='search_path') AS session_search_path
FROM pg_database WHERE datname = current_database();