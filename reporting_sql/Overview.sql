-- Overview tab queries for KSH Revenue Analytics dashboard
-- Co-authored with CoCo
/* ============================================================================
   TAB 1 — OVERVIEW
   Source tables: rpt_rev_monthly_summary, rpt_rev_leakage_summary,
                  rpt_rev_service_line_monthly
   All queries read from HOSPITALS.REPORTING.*
   ============================================================================ */



/* ----------------------------------------------------------------------------
   Q1_1 — KPI TILES (current month vs prior month)
   Returns: one row — all headline KPIs for the top tile row
   Used by: Gross Revenue, Avg Daily Revenue, Collection Rate, AR tiles
---------------------------------------------------------------------------- */
-- Anchor to latest available month in the table, not CURRENT_DATE.
-- Data runs to April 2026 — a CURRENT_DATE filter returns nothing.
WITH latest_month AS (
    SELECT MAX(rev_month) AS latest FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
),
current_month AS (
    SELECT s.*
    FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary s
    JOIN latest_month l ON s.rev_month = l.latest
),
prior_month AS (
    SELECT s.*
    FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary s
    JOIN latest_month l ON s.rev_month = DATEADD('month', -1, l.latest)
)
SELECT
    c.rev_month                                                         AS current_month,
    c.total_invoiced                                                    AS gross_revenue,
    c.avg_daily_revenue,
    c.collection_rate_pct,
    c.unique_patients,
    c.arpu_invoiced,
    c.undispatched_ar + c.dispatched_unpaid_ar                          AS total_open_ar,
    c.dispatch_rate_pct,
    -- MoM deltas
    ROUND((c.total_invoiced - p.total_invoiced)
          / NULLIF(p.total_invoiced, 0) * 100, 1)                      AS gross_revenue_mom_pct,
    ROUND((c.collection_rate_pct - p.collection_rate_pct), 1)          AS collection_rate_mom_delta,
    ROUND((c.unique_patients - p.unique_patients)
          / NULLIF(p.unique_patients, 0) * 100, 1)                     AS patients_mom_pct,
    c.total_invoiced - p.total_invoiced                                 AS gross_revenue_mom_kes,
    -- Prior month reference
    p.total_invoiced                                                    AS prior_month_revenue,
    p.rev_month                                                         AS prior_month
FROM current_month c
LEFT JOIN prior_month p ON 1 = 1;


/* ----------------------------------------------------------------------------
   Q1_2 — MONTHLY REVENUE TREND (12-month sparkline)
   Returns: one row per month, last 13 months (excludes Oct 2025)
   Used by: trend sparkline on Overview, YoY reference line
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_invoiced,
    cash_invoiced,
    insurer_invoiced,
    total_collected,
    collection_rate_pct,
    avg_daily_revenue,
    insurer_pct_of_total,
    -- Rolling 3-month average (smooths timing effects)
    ROUND(AVG(total_invoiced) OVER (
        ORDER BY rev_month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0)                                                               AS rolling_3m_avg_invoiced
FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
WHERE rev_month >= DATEADD('month', -13, (SELECT MAX(rev_month) FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary))
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q1_3 — LEAKAGE RADAR SUMMARY (for Overview leakage callout)
   Returns: all leakage vectors sorted by KES exposure
   Used by: top 3 leakage tiles on Overview
---------------------------------------------------------------------------- */
SELECT
    leakage_vector,
    event_count,
    leakage_kes,
    ROUND(leakage_kes
          / NULLIF(SUM(leakage_kes) OVER (), 0) * 100, 1)              AS pct_of_total_leakage
FROM HOSPITALS.REPORTING.rpt_rev_leakage_summary
WHERE leakage_kes IS NOT NULL
ORDER BY leakage_kes DESC;


/* ----------------------------------------------------------------------------
   Q1_4 — SIGNAL ENGINE (automated monitoring alerts)
   Returns: one row per signal that fires — empty = no alerts
   Each signal has: signal_name, severity (HIGH/MEDIUM), current_value,
   threshold_value, narrative
   Used by: Signals panel on Overview
---------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT *,
        -- 3-month rolling average for trend comparison
        AVG(total_invoiced) OVER (
            ORDER BY rev_month
            ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
        )                                                               AS prior_3m_avg,
        AVG(dispatch_rate_pct) OVER (
            ORDER BY rev_month
            ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
        )                                                               AS prior_3m_dispatch_avg
    FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
),
latest_m AS (
    SELECT MAX(rev_month) AS latest FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
),
current_m AS (
    SELECT monthly.*
    FROM monthly
    JOIN latest_m ON monthly.rev_month = latest_m.latest
),
service_line_current AS (
    -- Service line share for latest month vs prior month
    SELECT
        s.service_line,
        s.rev_month,
        s.pct_of_month_revenue                                          AS current_pct,
        LAG(s.pct_of_month_revenue) OVER (
            PARTITION BY s.service_line
            ORDER BY s.rev_month
        )                                                               AS prior_pct
    FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly s
    JOIN latest_m ON s.rev_month >= DATEADD('month', -2, latest_m.latest)
),
leakage AS (
    SELECT SUM(leakage_kes) AS total_leakage_kes
    FROM HOSPITALS.REPORTING.rpt_rev_leakage_summary
    WHERE leakage_kes IS NOT NULL
)
-- Signal 1: Revenue trending below rolling average
SELECT
    'Revenue Trend' AS signal_name,
    'HIGH'          AS severity,
    c.total_invoiced AS current_value,
    c.prior_3m_avg   AS threshold_value,
    'Current month revenue is more than 10% below the prior 3-month average' AS narrative
FROM current_m c
WHERE c.total_invoiced < c.prior_3m_avg * 0.90
  AND c.prior_3m_avg IS NOT NULL
 
UNION ALL
 
-- Signal 2: Dispatch rate collapse (current month <50% of prior 3-month avg)
SELECT
    'Dispatch Rate Collapse',
    'HIGH',
    c.dispatch_rate_pct,
    c.prior_3m_dispatch_avg,
    'Dispatch rate has dropped more than 50% below the prior 3-month average — insurer claims not being submitted'
FROM current_m c
WHERE c.dispatch_rate_pct < c.prior_3m_dispatch_avg * 0.50
  AND c.prior_3m_dispatch_avg IS NOT NULL
 
UNION ALL
 
-- Signal 3: SHA concentration risk (>35% of monthly invoiced)
SELECT
    'SHA Concentration Risk',
    'MEDIUM',
    c.insurer_pct_of_total,
    35.0,
    'SHA exceeds 35% of total invoiced revenue — high dependency on a single government payer'
FROM current_m c
WHERE c.insurer_pct_of_total > 35
 
UNION ALL
 
-- Signal 4: Collection rate below 8%
SELECT
    'Low Collection Rate',
    'HIGH',
    c.collection_rate_pct,
    8.0,
    'Collection rate has fallen below 8% — cash received is critically low relative to billings'
FROM current_m c
WHERE c.collection_rate_pct < 8.0
 
UNION ALL
 
-- Signal 5: Service line share drop >5pp MoM (any line)
SELECT
    'Service Line Share Drop — ' || service_line,
    'MEDIUM',
    current_pct,
    prior_pct,
    service_line || ' revenue share has dropped more than 5 percentage points month-over-month'
FROM service_line_current
JOIN latest_m ON service_line_current.rev_month = latest_m.latest
WHERE prior_pct IS NOT NULL
  AND (prior_pct - current_pct) > 5
 
UNION ALL
 
-- Signal 6: Total leakage exposure > KES 10M
SELECT
    'High Leakage Exposure',
    'MEDIUM',
    l.total_leakage_kes,
    10000000,
    'Total recoverable leakage exceeds KES 10M — review pharmacy dispensing and unbilled consultations'
FROM leakage l
WHERE l.total_leakage_kes > 10000000;
 



/* ----------------------------------------------------------------------------
   Q1_5 — PAYER MIX DONUT (current month)
   Returns: cash vs insurer split for the current month
   Used by: payer mix donut on Overview
---------------------------------------------------------------------------- */
SELECT
    CASE WHEN for_cash = 1 THEN 'Cash' ELSE 'Insurer' END AS payer_type,
    SUM(invoiced)                                          AS invoiced_kes,
    ROUND(SUM(invoiced)
          / NULLIF(SUM(SUM(invoiced)) OVER (), 0) * 100, 1) AS pct_of_total
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE rev_month = (SELECT MAX(rev_month) FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly)
GROUP BY 1
ORDER BY invoiced_kes DESC;