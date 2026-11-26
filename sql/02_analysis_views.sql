-- =====================================================================
-- Support Ticket Analysis — Step 2: analysis views
-- Each view feeds one dashboard visual. In Power BI:
-- Get Data > PostgreSQL database > pick the v_ views.
-- Medians are reported next to averages because resolution times
-- are skewed (a few very long tickets pull the average up).
-- =====================================================================

-- Drop old versions first so column changes never block a re-run
DROP VIEW IF EXISTS v_kpi_overview, v_time_by_priority, v_time_by_category, v_channel_performance, v_volume_monthly, v_volume_by_product_category, v_backlog_trend, v_bottleneck_subcategories, v_agent_performance, v_open_backlog_aging, v_sla_breaches, v_csat_breakdown CASCADE;

-- ---------------------------------------------------------------
-- KPI cards for the overview page (one row)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_overview AS
SELECT
    COUNT(*)                                                    AS total_tickets,
    COUNT(*) FILTER (WHERE is_open)                             AS open_backlog,
    ROUND(AVG(resolution_time_hrs), 1)                          AS avg_resolution_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1)     AS median_resolution_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY first_response_time_hrs)::NUMERIC, 1) AS median_first_response_hrs,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    ROUND(100.0 * AVG(reopened::INT), 1)                        AS reopen_rate_pct,
    ROUND(100.0 * AVG(escalated::INT), 1)                       AS escalation_rate_pct,
    ROUND(100.0 * AVG((first_response_time_hrs <= s.first_response_target_hrs)::INT), 1)
                                                                AS first_response_sla_met_pct,
    ROUND(100.0 * AVG((resolution_time_hrs <= s.resolution_target_hrs)::INT), 1)
                                                                AS resolution_sla_met_pct
FROM tickets t
JOIN sla_targets s USING (priority);

-- ---------------------------------------------------------------
-- 1. Resolution and response time
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_time_by_priority AS
SELECT
    t.priority,
    t.priority_rank,
    COUNT(*)                                                    AS tickets,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY first_response_time_hrs)::NUMERIC, 1) AS median_first_response_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1)     AS median_resolution_hrs,
    ROUND(AVG(resolution_time_hrs), 1)                          AS avg_resolution_hrs,
    s.first_response_target_hrs,
    ROUND(100.0 * AVG((first_response_time_hrs <= s.first_response_target_hrs)::INT), 1)
                                                                AS first_response_sla_met_pct,
    s.resolution_target_hrs,
    ROUND(100.0 * AVG((resolution_time_hrs <= s.resolution_target_hrs)::INT)
          FILTER (WHERE NOT is_open), 1)                        AS resolution_sla_met_pct
FROM tickets t
JOIN sla_targets s USING (priority)
GROUP BY t.priority, t.priority_rank, s.first_response_target_hrs, s.resolution_target_hrs
ORDER BY t.priority_rank;

CREATE OR REPLACE VIEW v_time_by_category AS
SELECT
    category,
    COUNT(*)                                                    AS tickets,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1) AS median_resolution_hrs,
    ROUND(AVG(resolution_time_hrs), 1)                          AS avg_resolution_hrs,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    ROUND(100.0 * AVG(reopened::INT), 1)                        AS reopen_rate_pct
FROM tickets
GROUP BY category
ORDER BY median_resolution_hrs DESC;

CREATE OR REPLACE VIEW v_channel_performance AS
SELECT
    channel,
    COUNT(*)                                                    AS tickets,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_tickets,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY first_response_time_hrs)::NUMERIC, 1) AS median_first_response_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1)     AS median_resolution_hrs,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat
FROM tickets
GROUP BY channel
ORDER BY tickets DESC;

-- ---------------------------------------------------------------
-- 2. Ticket volume
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_volume_monthly AS
SELECT
    created_month,
    COUNT(*)                                                    AS tickets_created,
    COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY created_month)      AS change_vs_prior_month,
    ROUND(AVG(COUNT(*)) OVER (ORDER BY created_month
          ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)         AS rolling_3mo_avg
FROM tickets
GROUP BY created_month
ORDER BY created_month;

-- "Department" view: which product and category generate the work
CREATE OR REPLACE VIEW v_volume_by_product_category AS
SELECT
    product,
    category,
    COUNT(*)                                                    AS tickets,
    COUNT(*) FILTER (WHERE is_open)                             AS open_backlog
FROM tickets
GROUP BY product, category
ORDER BY product, tickets DESC;

-- Created vs. resolved each month, and the running backlog that produces
CREATE OR REPLACE VIEW v_backlog_trend AS
WITH created AS (
    SELECT created_month AS m, COUNT(*) AS n FROM tickets GROUP BY 1
), resolved AS (
    SELECT DATE_TRUNC('month', resolved_at)::DATE AS m, COUNT(*) AS n
    FROM tickets WHERE resolved_at IS NOT NULL GROUP BY 1
), months AS (
    SELECT m FROM created UNION SELECT m FROM resolved
)
SELECT
    months.m                                                    AS month,
    COALESCE(c.n, 0)                                            AS created,
    COALESCE(r.n, 0)                                            AS resolved,
    SUM(COALESCE(c.n, 0) - COALESCE(r.n, 0)) OVER (ORDER BY months.m) AS running_backlog
FROM months
LEFT JOIN created  c ON c.m = months.m
LEFT JOIN resolved r ON r.m = months.m
ORDER BY month;

-- ---------------------------------------------------------------
-- 3. Bottlenecks
-- ---------------------------------------------------------------
-- Subcategories ranked by total hours consumed (volume x time).
-- High-volume, repetitive issues here are candidates for
-- self-service articles or automation.
CREATE OR REPLACE VIEW v_bottleneck_subcategories AS
SELECT
    category,
    subcategory,
    COUNT(*)                                                    AS tickets,
    ROUND(SUM(resolution_time_hrs), 0)                          AS total_resolution_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1) AS median_resolution_hrs,
    COUNT(*) FILTER (WHERE is_open)                             AS open_backlog,
    ROUND(100.0 * AVG(reopened::INT), 1)                        AS reopen_rate_pct,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    RANK() OVER (ORDER BY SUM(resolution_time_hrs) DESC NULLS LAST) AS hours_rank
FROM tickets
GROUP BY category, subcategory;

-- Agent workload and quality
CREATE OR REPLACE VIEW v_agent_performance AS
SELECT
    agent_name,
    COUNT(*)                                                    AS tickets,
    COUNT(*) FILTER (WHERE is_open)                             AS open_backlog,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY first_response_time_hrs)::NUMERIC, 1) AS median_first_response_hrs,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_time_hrs)::NUMERIC, 1)     AS median_resolution_hrs,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    ROUND(100.0 * AVG(reopened::INT), 1)                        AS reopen_rate_pct,
    ROUND(100.0 * AVG(escalated::INT), 1)                       AS escalation_rate_pct
FROM tickets
GROUP BY agent_name
ORDER BY tickets DESC;

-- Where open tickets are sitting, by priority and age
CREATE OR REPLACE VIEW v_open_backlog_aging AS
SELECT
    priority,
    priority_rank,
    status,
    COUNT(*)                                                    AS open_tickets,
    COUNT(*) FILTER (WHERE first_response_time_hrs IS NULL)     AS never_responded
FROM tickets
WHERE is_open
GROUP BY priority, priority_rank, status
ORDER BY priority_rank, status;

-- SLA breaches by priority and channel
CREATE OR REPLACE VIEW v_sla_breaches AS
SELECT
    t.priority,
    t.priority_rank,
    t.channel,
    COUNT(*)                                                    AS tickets,
    COUNT(*) FILTER (WHERE first_response_time_hrs > s.first_response_target_hrs)
                                                                AS first_response_breaches,
    ROUND(100.0 * AVG((first_response_time_hrs > s.first_response_target_hrs)::INT), 1)
                                                                AS first_response_breach_pct
FROM tickets t
JOIN sla_targets s USING (priority)
GROUP BY t.priority, t.priority_rank, t.channel
ORDER BY t.priority_rank, first_response_breach_pct DESC;

-- Customer satisfaction by sentiment and plan
CREATE OR REPLACE VIEW v_csat_breakdown AS
SELECT
    customer_plan,
    sentiment,
    COUNT(csat_score)                                           AS rated_tickets,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    ROUND(100.0 * AVG((csat_score <= 2)::INT), 1)               AS pct_unhappy   -- 1–2 out of 5
FROM tickets
WHERE csat_score IS NOT NULL
GROUP BY customer_plan, sentiment
ORDER BY customer_plan, avg_csat;

-- ---------------------------------------------------------------
-- Quick look: priority and top 10 bottlenecks
-- ---------------------------------------------------------------
SELECT priority, tickets, median_first_response_hrs, median_resolution_hrs,
       first_response_sla_met_pct, resolution_sla_met_pct
FROM v_time_by_priority;

SELECT category, subcategory, tickets, total_resolution_hrs,
       median_resolution_hrs, reopen_rate_pct
FROM v_bottleneck_subcategories
WHERE hours_rank <= 10
ORDER BY hours_rank;
