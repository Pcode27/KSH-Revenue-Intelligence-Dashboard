-- Revenue Pulse tab queries using MAX(rev_month) instead of CURRENT_DATE
-- Co-authored with CoCo
/* ============================================================================
   TAB 2 — REVENUE PULSE
   Source tables: rpt_rev_monthly_summary, rpt_rev_service_line_monthly,
                  rpt_rev_timing, rpt_rev_top_items
   Questions answered:
     - How is total revenue trending?
     - What are the revenue drivers (volume vs intensity vs mix)?
     - Which service lines are growing or shrinking?
     - When do we make the most money?
     - What are the top revenue items?
     - 90-day revenue forecast
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q2_1 — MONTHLY BILLING TREND (full history)
   Returns: one row per month, all time
   Used by: main trend chart, YoY overlay
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_invoiced,
    cash_invoiced,
    insurer_invoiced,
    invoice_count,
    avg_invoice_amount,
    avg_daily_revenue,
    insurer_pct_of_total,
    -- Rolling averages
    ROUND(AVG(total_invoiced) OVER (
        ORDER BY rev_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0)                                                               AS rolling_3m_avg,
    ROUND(AVG(total_invoiced) OVER (
        ORDER BY rev_month ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
    ), 0)                                                               AS rolling_6m_avg,
    -- MoM delta
    total_invoiced - LAG(total_invoiced) OVER (ORDER BY rev_month)     AS mom_delta_kes,
    ROUND((total_invoiced - LAG(total_invoiced) OVER (ORDER BY rev_month))
          / NULLIF(LAG(total_invoiced) OVER (ORDER BY rev_month), 0) * 100, 1)
                                                                        AS mom_delta_pct
FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q2_2 — REVENUE DRIVER DECOMPOSITION (volume vs intensity vs mix)
   Returns: one row per month — splits revenue change into components
   Used by: "What are the revenue drivers?" section
   - Volume effect: change in invoice count × prior avg invoice amount
   - Intensity effect: change in avg invoice amount × current count
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_invoiced,
    invoice_count,
    avg_invoice_amount,
    unique_patients,
    arpu_invoiced,
    -- Volume effect (more invoices at same price)
    ROUND((invoice_count - LAG(invoice_count) OVER (ORDER BY rev_month))
          * LAG(avg_invoice_amount) OVER (ORDER BY rev_month), 0)       AS volume_effect_kes,
    -- Intensity effect (same volume at higher price)
    ROUND((avg_invoice_amount - LAG(avg_invoice_amount) OVER (ORDER BY rev_month))
          * LAG(invoice_count) OVER (ORDER BY rev_month), 0)            AS intensity_effect_kes,
    -- Patient volume
    invoice_count - LAG(invoice_count) OVER (ORDER BY rev_month)        AS invoice_count_mom_delta,
    avg_invoice_amount - LAG(avg_invoice_amount) OVER (ORDER BY rev_month)
                                                                        AS avg_invoice_mom_delta
FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q2_3 — SERVICE LINE TREND (monthly, all lines)
   Returns: one row per service_line × month
   Used by: stacked area chart, share trend
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    service_line,
    revenue,
    line_items,
    pct_of_month_revenue,
    mom_revenue_delta,
    ROUND(mom_revenue_delta / NULLIF(revenue - mom_revenue_delta, 0) * 100, 1)
                                                                        AS mom_delta_pct
FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly
ORDER BY rev_month, revenue DESC;


 

/* ----------------------------------------------------------------------------
   Q2_4 — SERVICE LINE SHARE SHIFT (current vs 6 months ago)
   Returns: one row per service line — shows structural shift
   Used by: "Is any service line growing or shrinking?" callout
---------------------------------------------------------------------------- */
WITH latest AS (
    SELECT MAX(rev_month) AS latest_month
    FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly
),
current_m AS (
    SELECT service_line, revenue, pct_of_month_revenue
    FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly
    JOIN latest ON rev_month = latest_month
),
five_months_ago AS (
    -- -6 months from April 2026 = October 2025 which is excluded.
    -- Using -5 months (November 2025) as the nearest clean comparison point.
    SELECT service_line, revenue AS revenue_6m, pct_of_month_revenue AS pct_6m
    FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly
    JOIN latest ON rev_month = DATEADD('month', -5, latest_month)
)
SELECT
    c.service_line,
    c.revenue                                                           AS current_revenue,
    c.pct_of_month_revenue                                             AS current_pct,
    s.revenue_6m                                                        AS revenue_6m_ago,
    s.pct_6m                                                            AS pct_6m_ago,
    ROUND(c.pct_of_month_revenue - s.pct_6m, 1)                       AS share_shift_pp,
    ROUND((c.revenue - s.revenue_6m) / NULLIF(s.revenue_6m, 0) * 100, 1)
                                                                        AS revenue_growth_6m_pct
    -- Comparison: April 2026 vs November 2025 (Oct 2025 excluded — next available prior month used)
FROM current_m c
LEFT JOIN five_months_ago s ON c.service_line = s.service_line
ORDER BY share_shift_pp DESC;
 


/* ----------------------------------------------------------------------------
   Q2_5 — REVENUE TIMING — DAY OF WEEK PATTERN
   Returns: one row per day of week, sorted Mon→Sun
   Used by: "When do we make the most money?" bar chart
---------------------------------------------------------------------------- */
SELECT
    day_of_week_num,
    day_of_week_name,
    avg_daily_invoiced,
    median_daily_invoiced,
    avg_daily_invoices,
    total_invoiced,
    data_days,
    -- Index relative to weekly average (100 = average day)
    ROUND(avg_daily_invoiced
          / NULLIF(AVG(avg_daily_invoiced) OVER (), 0) * 100, 1)       AS daily_revenue_index
FROM HOSPITALS.REPORTING.rpt_rev_timing
GROUP BY 1, 2, avg_daily_invoiced, median_daily_invoiced,
         avg_daily_invoices, total_invoiced, data_days
ORDER BY day_of_week_num;


/* ----------------------------------------------------------------------------
   Q2_6 — REVENUE TIMING — WEEK OF MONTH PATTERN
   Returns: one row per week bucket
   Used by: "When do we make the most money?" secondary chart
---------------------------------------------------------------------------- */
SELECT
    week_of_month,
    ROUND(AVG(avg_daily_invoiced), 0)                                  AS avg_daily_invoiced,
    ROUND(SUM(total_invoiced) / NULLIF(SUM(data_days), 0), 0)          AS effective_daily_avg,
    SUM(total_invoiced)                                                 AS total_invoiced,
    SUM(data_days)                                                      AS total_days_sampled
FROM HOSPITALS.REPORTING.rpt_rev_timing
GROUP BY 1
ORDER BY
    CASE week_of_month
        WHEN 'Week 1 (1–7)'   THEN 1
        WHEN 'Week 2 (8–14)'  THEN 2
        WHEN 'Week 3 (15–21)' THEN 3
        ELSE 4
    END;


/* ----------------------------------------------------------------------------
   Q2_7 — TOP REVENUE ITEMS (top 30 by total revenue)
   Returns: one row per item, ranked by total revenue
   Used by: "Top revenue items" ranked table
---------------------------------------------------------------------------- */
SELECT
    service_line,
    item_name,
    store_code,
    item_classify,
    times_billed,
    unique_invoices,
    total_revenue,
    avg_unit_price,
    median_unit_price,
    pct_of_service_line_revenue,
    first_billed,
    last_billed
FROM HOSPITALS.REPORTING.rpt_rev_top_items
ORDER BY total_revenue DESC
LIMIT 30;


/* ----------------------------------------------------------------------------
   Q2_8 — TOP ITEMS BY SERVICE LINE (top 10 per line)
   Returns: one row per service_line × item_name, top 10 within each line
   Used by: service line drill-down expandable table
---------------------------------------------------------------------------- */
SELECT
    service_line,
    item_name,
    times_billed,
    total_revenue,
    avg_unit_price,
    pct_of_service_line_revenue
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY service_line ORDER BY total_revenue DESC
        ) AS rank_within_line
    FROM HOSPITALS.REPORTING.rpt_rev_top_items
)
WHERE rank_within_line <= 10
ORDER BY service_line, total_revenue DESC;


/* ----------------------------------------------------------------------------
   Q2_9 — 90-DAY REVENUE FORECAST (rolling average projection)
   Returns: one row per projected month (next 3 months)
   Method: 6-month rolling average as baseline, MoM growth rate applied
   Label clearly as indicative — not a regression model.
   Used by: forecast chart extension beyond current month
---------------------------------------------------------------------------- */
WITH monthly_with_lag AS (
    SELECT
        rev_month,
        total_invoiced,
        LAG(total_invoiced) OVER (ORDER BY rev_month) AS prior_invoiced
    FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
),
recent AS (
    SELECT
        rev_month,
        total_invoiced,
        AVG(total_invoiced) OVER (
            ORDER BY rev_month ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
        )                                                               AS rolling_6m_avg,
        -- Average MoM growth rate over last 6 months
        AVG((total_invoiced - prior_invoiced)
            / NULLIF(prior_invoiced, 0))
        OVER (ORDER BY rev_month ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
                                                                        AS avg_mom_growth_rate
    FROM monthly_with_lag
    WHERE prior_invoiced IS NOT NULL
),
latest AS (
    SELECT * FROM recent
    ORDER BY rev_month DESC
    LIMIT 1
)
SELECT
    DATEADD('month', n.n, l.rev_month)                                 AS forecast_month,
    ROUND(l.rolling_6m_avg * POWER(1 + l.avg_mom_growth_rate, n.n), 0) AS forecast_invoiced,
    ROUND(l.rolling_6m_avg, 0)                                         AS flat_baseline,
    'Indicative only — 6-month rolling average with historical growth rate applied' AS methodology_note
FROM latest l
CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3) n
ORDER BY forecast_month;