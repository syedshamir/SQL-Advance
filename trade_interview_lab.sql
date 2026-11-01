-- PostgreSQL interview practice.
-- Run the setup once, then highlight and execute each labelled query.
-- Re-running setup deliberately replaces only the trade_interview_lab schema.
BEGIN;
DROP SCHEMA IF EXISTS trade_interview_lab CASCADE;
CREATE SCHEMA trade_interview_lab;
CREATE TABLE trade_interview_lab.orders (
    order_id integer PRIMARY KEY,
    instrument text NOT NULL,
    ordered_qty integer NOT NULL CHECK (ordered_qty > 0)
);
CREATE TABLE trade_interview_lab.fill_revisions (
    fill_id integer NOT NULL,
    revision integer NOT NULL,
    order_id integer NOT NULL REFERENCES trade_interview_lab.orders,
    executed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL,
    qty integer NOT NULL CHECK (qty > 0),
    price numeric(12,2) NOT NULL CHECK (price > 0),
    PRIMARY KEY (fill_id, revision)
);

-- This table is intentionally shaped to match the interview LAG() question.
CREATE TABLE trade_interview_lab.executions (
    trade_id integer PRIMARY KEY,
    instrument_id text NOT NULL,
    venue_id text NOT NULL,
    session_id date NOT NULL,
    exchange_seq integer NOT NULL,
    price numeric(12,2) NOT NULL CHECK (price > 0),
    UNIQUE (instrument_id, venue_id, session_id, exchange_seq)
);

-- A risk result has one value for a portfolio, valuation time, scenario and run.
-- The run records the version of the model and the exact calculation that produced it.
CREATE TABLE trade_interview_lab.risk_runs (
    risk_run_id integer PRIMARY KEY,
    model_version text NOT NULL,
    input_cutoff timestamptz NOT NULL,
    completed_at timestamptz NOT NULL
);

CREATE TABLE trade_interview_lab.risk_results (
    risk_run_id integer NOT NULL REFERENCES trade_interview_lab.risk_runs,
    portfolio_id integer NOT NULL,
    scenario_name text NOT NULL,
    metric_name text NOT NULL,
    metric_value numeric(18,2) NOT NULL,
    PRIMARY KEY (risk_run_id, portfolio_id, scenario_name, metric_name)
);
INSERT INTO trade_interview_lab.orders VALUES
    (1, 'ACME', 100), (2, 'BETA', 50), (3, 'ACME', 20);
-- All orders are buys in USD on one venue. Order 3 has no fills.
-- fill_id, revision, order_id, executed_at, received_at, qty, price
INSERT INTO trade_interview_lab.fill_revisions VALUES
    (101, 1, 1, '2026-10-26 14:00+00', '2026-10-26 14:00:01+00', 60, 100),
    (102, 1, 1, '2026-10-26 14:01+00', '2026-10-26 14:01:01+00', 40, 110),
    (201, 1, 2, '2026-10-26 14:02+00', '2026-10-26 14:02:01+00', 30,  50),
    (102, 2, 1, '2026-10-26 14:01+00', '2026-10-27 09:00:00+00', 40, 101);

-- ACME trade 1002 rises from 100 to 110, a 10% anomaly.
-- BETA changes by only 2%, so it is not returned by the 5% rule.
INSERT INTO trade_interview_lab.executions VALUES
    (1001, 'ACME', 'XNYS', DATE '2026-10-26', 1, 100.00),
    (1002, 'ACME', 'XNYS', DATE '2026-10-26', 2, 110.00),
    (1003, 'ACME', 'XNYS', DATE '2026-10-26', 3, 108.00),
    (2001, 'BETA', 'XNAS', DATE '2026-10-26', 1,  50.00),
    (2002, 'BETA', 'XNAS', DATE '2026-10-26', 2,  51.00);

INSERT INTO trade_interview_lab.risk_runs VALUES
    (9001, 'var-model-2.3', '2026-10-26 21:00+00', '2026-10-26 21:05+00');

INSERT INTO trade_interview_lab.risk_results VALUES
    (9001, 10, 'BASE', 'VALUE_AT_RISK_99', 12500.00),
    (9001, 10, 'MARKET_DOWN_5_PCT', 'VALUE_AT_RISK_99', 42800.00);

CREATE VIEW trade_interview_lab.current_fills AS
SELECT fill_id, revision, order_id, executed_at, qty, price
FROM (
    SELECT f.*, ROW_NUMBER() OVER (
        PARTITION BY fill_id ORDER BY revision DESC
    ) AS rn
    FROM trade_interview_lab.fill_revisions AS f
) AS ranked
WHERE rn = 1;
COMMIT;

-- 1. Inspect the history. Which two rows refer to the same fill?
SELECT * FROM trade_interview_lab.fill_revisions ORDER BY fill_id, revision;

-- 2. Compare with query 1. Why does this return three rows instead of four?
SELECT * FROM trade_interview_lab.current_fills ORDER BY fill_id;

-- 3. Show filled, outstanding and traded value, including orders with no fills.
SELECT o.order_id, o.ordered_qty, COALESCE(SUM(f.qty), 0) AS filled,
       o.ordered_qty - COALESCE(SUM(f.qty), 0) AS outstanding,
       COALESCE(SUM(f.qty * f.price), 0) AS traded_value
FROM trade_interview_lab.orders AS o
LEFT JOIN trade_interview_lab.current_fills AS f ON f.order_id = o.order_id
GROUP BY o.order_id, o.ordered_qty
ORDER BY o.order_id;

-- 4. Window function for trade anomalies.
-- This is the same query structure as the interview example.
WITH priced AS (
    SELECT
        trade_id,
        instrument_id,
        venue_id,
        session_id,
        exchange_seq,
        price,
        LAG(price) OVER (
            PARTITION BY instrument_id, venue_id, session_id
            ORDER BY exchange_seq
        ) AS previous_price
    FROM trade_interview_lab.executions
)
SELECT
    trade_id,
    price,
    previous_price,
    ROUND(100.0 * (price - previous_price) / previous_price, 2)
        AS change_pct
FROM priced
WHERE previous_price > 0
  AND ABS(price - previous_price) >= 0.05 * previous_price;

-- 5. Deliberate bug. Explain the 140 shares, then change the FROM table
-- to trade_interview_lab.current_fills and compare the results.
SELECT SUM(qty) AS filled, SUM(qty * price) AS traded_value
FROM trade_interview_lab.fill_revisions
WHERE order_id = 1;

-- 6. Risk schema. Retrieve values from one reproducible risk run.
-- The run identifies the model and input cutoff that generated the result.
SELECT r.risk_run_id, r.model_version, r.input_cutoff,
       x.portfolio_id, x.scenario_name, x.metric_name, x.metric_value
FROM trade_interview_lab.risk_runs AS r
JOIN trade_interview_lab.risk_results AS x ON x.risk_run_id = r.risk_run_id
WHERE r.risk_run_id = 9001
ORDER BY x.scenario_name;

-- 7. Optimisation baseline. Read the execution plan before adding an index.
-- In a production-sized table, the planner may show a Sequential Scan here.
EXPLAIN (ANALYZE, BUFFERS)
SELECT fill_id, revision, order_id, executed_at, qty, price
FROM trade_interview_lab.fill_revisions
WHERE order_id = 1
  AND executed_at >= TIMESTAMPTZ '2026-10-26 00:00+00'
  AND executed_at <  TIMESTAMPTZ '2026-10-27 00:00+00';

-- 8. Create an index aligned to query 7's equality filter and time range.
CREATE INDEX fill_revisions_order_time_idx
    ON trade_interview_lab.fill_revisions (order_id, executed_at)
    INCLUDE (fill_id, revision, qty, price);

-- 9. Rerun query 7 after the index exists. Compare its plan, buffers and time.
-- On this tiny training data PostgreSQL can still choose a Sequential Scan.
-- The lesson is to validate with realistic volumes before declaring an index useful.
EXPLAIN (ANALYZE, BUFFERS)
SELECT fill_id, revision, order_id, executed_at, qty, price
FROM trade_interview_lab.fill_revisions
WHERE order_id = 1
  AND executed_at >= TIMESTAMPTZ '2026-10-26 00:00+00'
  AND executed_at <  TIMESTAMPTZ '2026-10-27 00:00+00';
