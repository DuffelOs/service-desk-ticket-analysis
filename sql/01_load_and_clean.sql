-- =====================================================================
-- Support Ticket Analysis — Step 1: load and clean
-- Dataset: support_tickets_kaggle.csv (2,000 tickets, Jan 2024 – Jun 2025)
-- Database: PostgreSQL 14+
-- Run in psql:  \i 01_load_and_clean.sql
-- Change the file path on the \copy line to where your CSV is saved.
-- =====================================================================

DROP TABLE IF EXISTS tickets_raw CASCADE;
DROP TABLE IF EXISTS tickets     CASCADE;
DROP TABLE IF EXISTS sla_targets CASCADE;

-- 1. Staging table: every column as text, so the import never fails on a bad value
CREATE TABLE tickets_raw (
    ticket_id                TEXT,
    created_at               TEXT,
    resolved_at              TEXT,
    channel                  TEXT,
    category                 TEXT,
    subcategory              TEXT,
    priority                 TEXT,
    status                   TEXT,
    sentiment                TEXT,
    product                  TEXT,
    customer_plan            TEXT,
    region                   TEXT,
    language                 TEXT,
    assigned_agent           TEXT,
    message                  TEXT,
    resolution_note          TEXT,
    resolution_time_hrs      TEXT,
    csat_score               TEXT,
    first_response_time_hrs  TEXT,
    reopened                 TEXT,
    escalated                TEXT,
    num_interactions         TEXT,
    customer_tenure_days     TEXT
);

-- psql client-side copy. In DBeaver/pgAdmin instead:
-- right-click tickets_raw > Import Data > CSV.
\copy tickets_raw FROM 'support_tickets_kaggle.csv' WITH (FORMAT csv, HEADER true)

-- 2. Clean, typed table
CREATE TABLE tickets (
    ticket_id                TEXT PRIMARY KEY,
    created_at               TIMESTAMP NOT NULL,
    resolved_at              TIMESTAMP,
    created_month            DATE NOT NULL,       -- first of month, for trend charts
    channel                  TEXT NOT NULL,
    category                 TEXT NOT NULL,
    subcategory              TEXT NOT NULL,
    priority                 TEXT NOT NULL,
    priority_rank            SMALLINT NOT NULL,   -- 1 = Critical ... 4 = Low, for sorting
    status                   TEXT NOT NULL,
    is_open                  BOOLEAN NOT NULL,    -- no resolved_at = still in the backlog
    sentiment                TEXT NOT NULL,
    product                  TEXT NOT NULL,
    customer_plan            TEXT NOT NULL,
    region                   TEXT NOT NULL,
    language                 TEXT NOT NULL,
    agent_name               TEXT NOT NULL,       -- 'Priya S' instead of 'Agent_001 (Priya S)'
    is_unassigned            BOOLEAN NOT NULL,
    message                  TEXT,
    resolution_note          TEXT,
    resolution_time_hrs      NUMERIC(7,1),
    first_response_time_hrs  NUMERIC(6,1),
    csat_score               NUMERIC(3,1),        -- 1–5, only collected on Resolved/Closed
    reopened                 BOOLEAN NOT NULL,
    escalated                BOOLEAN NOT NULL,
    num_interactions         SMALLINT NOT NULL,
    customer_tenure_days     INTEGER NOT NULL
);

INSERT INTO tickets
SELECT
    TRIM(ticket_id),
    created_at::TIMESTAMP,
    NULLIF(TRIM(resolved_at), '')::TIMESTAMP,
    DATE_TRUNC('month', created_at::TIMESTAMP)::DATE,
    -- 'helpdesk_portal' -> 'Helpdesk Portal', with brand spellings fixed
    REPLACE(REPLACE(INITCAP(REPLACE(TRIM(channel), '_', ' ')),
            'Twitter Dm', 'Twitter DM'), 'Whatsapp', 'WhatsApp'),
    TRIM(category),
    TRIM(subcategory),
    INITCAP(TRIM(priority)),
    CASE INITCAP(TRIM(priority))
        WHEN 'Critical' THEN 1 WHEN 'High' THEN 2
        WHEN 'Medium'   THEN 3 WHEN 'Low'  THEN 4 END,
    TRIM(status),
    NULLIF(TRIM(resolved_at), '') IS NULL,
    TRIM(sentiment),
    TRIM(product),
    TRIM(customer_plan),
    TRIM(region),
    TRIM(language),
    -- pull the name out of the parentheses; keep 'Unassigned' as is
    COALESCE(SUBSTRING(assigned_agent FROM '\((.*)\)'), TRIM(assigned_agent)),
    TRIM(assigned_agent) = 'Unassigned',
    NULLIF(TRIM(message), ''),
    NULLIF(TRIM(resolution_note), ''),
    NULLIF(TRIM(resolution_time_hrs), '')::NUMERIC(7,1),
    NULLIF(TRIM(first_response_time_hrs), '')::NUMERIC(6,1),
    NULLIF(TRIM(csat_score), '')::NUMERIC(3,1),
    LOWER(TRIM(reopened))  IN ('true', '1', 'yes'),
    LOWER(TRIM(escalated)) IN ('true', '1', 'yes'),
    num_interactions::SMALLINT,
    customer_tenure_days::INTEGER
FROM tickets_raw;

CREATE INDEX ON tickets (created_month);
CREATE INDEX ON tickets (category, subcategory);
CREATE INDEX ON tickets (agent_name, is_open);

-- 3. SLA targets by priority (illustrative — state these as assumptions in your README)
CREATE TABLE sla_targets (
    priority                 TEXT PRIMARY KEY,
    first_response_target_hrs NUMERIC(5,1) NOT NULL,
    resolution_target_hrs     NUMERIC(5,1) NOT NULL
);
INSERT INTO sla_targets VALUES
    ('Critical',  1,  24),
    ('High',      4,  48),
    ('Medium',    8,  72),
    ('Low',      24, 120);

-- 4. Sanity check: expect 2000 rows and 0 unknown priorities
SELECT COUNT(*) AS row_count,
       COUNT(*) FILTER (WHERE priority_rank IS NULL) AS unknown_priority,
       COUNT(*) FILTER (WHERE is_open)               AS open_tickets
FROM tickets;
