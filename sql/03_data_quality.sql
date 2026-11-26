-- =====================================================================
-- Support Ticket Analysis — Step 3: data-quality audit
-- Run before trusting the dashboard. Summarize the results in your README.
-- =====================================================================

-- 1. Does status agree with resolved_at?
--    Expect: Open / In Progress have no resolved date; everything else does.
SELECT
    status,
    COUNT(*)                                                    AS tickets,
    COUNT(*) FILTER (WHERE resolved_at IS NOT NULL)             AS has_resolved_at,
    COUNT(*) FILTER (WHERE csat_score  IS NOT NULL)             AS has_csat
FROM tickets
GROUP BY status
ORDER BY status;

-- 2. Does resolution_time_hrs match resolved_at - created_at?
SELECT
    COUNT(*)                                                    AS resolved_tickets,
    COUNT(*) FILTER (WHERE ABS(EXTRACT(EPOCH FROM resolved_at - created_at) / 3600
                               - resolution_time_hrs) > 0.1)    AS mismatched
FROM tickets
WHERE resolved_at IS NOT NULL;

-- 3. Impossible timelines: first response came after the ticket was resolved
SELECT COUNT(*) AS first_response_after_resolution
FROM tickets
WHERE first_response_time_hrs > resolution_time_hrs;

-- 4. Missing values by column
SELECT
    COUNT(*) FILTER (WHERE first_response_time_hrs IS NULL)     AS no_first_response,
    COUNT(*) FILTER (WHERE resolution_note IS NULL)             AS no_resolution_note,
    COUNT(*) FILTER (WHERE is_unassigned)                       AS unassigned,
    COUNT(*) FILTER (WHERE is_unassigned AND first_response_time_hrs IS NULL)
                                                                AS unassigned_and_no_response
FROM tickets;

-- 5. Resolution notes that contradict status
--    e.g. 'Issue fixed by agent' on a ticket that is still open
SELECT status, resolution_note, COUNT(*) AS tickets
FROM tickets
WHERE is_open AND resolution_note IN ('Issue fixed by agent', 'Refund processed')
GROUP BY status, resolution_note
ORDER BY tickets DESC;

-- 6. Date coverage
SELECT MIN(created_at) AS first_ticket,
       MAX(created_at) AS last_ticket,
       COUNT(DISTINCT created_month) AS months_covered
FROM tickets;
