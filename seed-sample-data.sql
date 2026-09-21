-- Sample data for the hands-on labs in hands-on-labs-guide.md.
-- Run once, against either the Tanzu or open-source container, before starting the labs:
--
--   docker cp seed-sample-data.sql <container>:/tmp/seed.sql
--   docker exec <container> psql -U appuser -d appdb -f /tmp/seed.sql
--
-- Safe to run only once per fresh database - it doesn't drop/recreate if the tables
-- already exist (rerun the labs guide's cleanup step first if you want a clean reset).

CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT,
    country TEXT
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    total NUMERIC(10,2)
);

INSERT INTO customers (name, city, country) VALUES
    ('Aman', 'Bengaluru', 'IN'),
    ('Priya', 'Mumbai', 'IN'),
    ('Mira', 'Singapore', 'SG'),
    ('Wei', 'Shanghai', 'CN'),
    ('Sara', 'London', 'UK');

-- customer id 42 is used by the indexing lab's WHERE customer_id = 42
INSERT INTO customers (id, name, city, country) VALUES (42, 'Trainer Demo Customer', 'Austin', 'US');
SELECT setval('customers_id_seq', (SELECT max(id) FROM customers));

-- bulk-load orders so the planner actually has a reason to prefer an index over a seq scan
-- (a handful of rows won't show a plan change - this needs real volume)
INSERT INTO orders (customer_id, total)
SELECT (random() * 4 + 1)::int, round((random() * 500)::numeric, 2)
FROM generate_series(1, 50000);

-- guarantee a meaningful number of rows for customer_id = 42 specifically
INSERT INTO orders (customer_id, total)
SELECT 42, round((random() * 500)::numeric, 2)
FROM generate_series(1, 25);

ANALYZE customers;
ANALYZE orders;
