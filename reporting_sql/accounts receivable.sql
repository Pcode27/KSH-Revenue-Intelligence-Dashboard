/* ============================================================================
   TAB 5 — ACCOUNTS RECEIVABLE
   Source tables: rpt_rev_ar_snapshot, rpt_rev_ar_aging,
                  rpt_rev_payer_monthly, rpt_rev_monthly_summary
   Questions answered:
     - What is total open AR and how is it split?
     - How is AR aged across 0–30 / 31–60 / 61–90 / 90+ buckets?
     - Which insurers have the oldest AR?
     - How long is the billing team sitting on claims (dispatch lag)?
     - How long are insurers sitting on claims after dispatch?
     - Is the dispatch rate improving or declining?
     - What is the NULL company_id blind spot?
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q5_1 — AR HEADLINE KPIs (snapshot)
   Returns: single row — all AR headline numbers for KPI tiles
   Used by: top KPI tiles on AR tab
---------------------------------------------------------------------------- */
SELECT
    SUM(open_invoices)                                                  AS total_open_invoices,
    SUM(outstanding_kes)                                                AS total_ar_kes,
    SUM(CASE WHEN ar_state = 'Undispatched — Claim Not Sent'
             THEN outstanding_kes ELSE 0 END)                          AS undispatched_ar_kes,
    SUM(CASE WHEN ar_state = 'Dispatched — Awaiting Payment'
             THEN outstanding_kes ELSE 0 END)                          AS dispatched_unpaid_ar_kes,
    SUM(CASE WHEN insurer_label = '⚠ Unknown (NULL company_id)'
             THEN outstanding_kes ELSE 0 END)                          AS unknown_insurer_ar_kes,
    ROUND(SUM(CASE WHEN ar_state = 'Undispatched — Claim Not Sent'
                   THEN outstanding_kes ELSE 0 END)
          / NULLIF(SUM(outstanding_kes), 0) * 100, 1)                 AS undispatched_pct,
    MAX(snapshot_date)                                                  AS as_of_date
FROM HOSPITALS.REPORTING.rpt_rev_ar_snapshot;


/* ----------------------------------------------------------------------------
   Q5_2 — AR BY INSURER AND STATE (full table)
   Returns: one row per insurer × AR state, sorted by outstanding KES
   Used by: main AR table on the tab
---------------------------------------------------------------------------- */
SELECT
    insurer_label,
    payer_class,
    ar_state,
    open_invoices,
    outstanding_kes,
    avg_days_outstanding,
    median_days_outstanding,
    pct_of_insurer_ar,
    avg_days_to_dispatch,
    oldest_invoice,
    newest_invoice,
    snapshot_date
FROM HOSPITALS.REPORTING.rpt_rev_ar_snapshot
ORDER BY outstanding_kes DESC;


/* ----------------------------------------------------------------------------
   Q5_3 — AR AGING HEATMAP (insurer × bucket)
   Returns: one row per insurer × AR state × aging bucket
   Used by: aging heatmap / stacked bar chart
---------------------------------------------------------------------------- */
SELECT
    insurer_label,
    payer_class,
    ar_state,
    aging_bucket,
    bucket_sort,
    invoice_count,
    outstanding_kes,
    avg_days,
    snapshot_date
FROM HOSPITALS.REPORTING.rpt_rev_ar_aging
ORDER BY outstanding_kes DESC, bucket_sort;


/* ----------------------------------------------------------------------------
   Q5_4 — AGING BUCKET SUMMARY (across all insurers)
   Returns: one row per aging bucket — total exposure in each bucket
   Used by: headline aging summary bar chart
---------------------------------------------------------------------------- */
SELECT
    aging_bucket,
    ar_state,
    bucket_sort,
    SUM(invoice_count)                                                  AS total_invoices,
    SUM(outstanding_kes)                                                AS total_outstanding_kes,
    ROUND(SUM(outstanding_kes)
          / NULLIF(SUM(SUM(outstanding_kes)) OVER (), 0) * 100, 1)    AS pct_of_total_ar
FROM HOSPITALS.REPORTING.rpt_rev_ar_aging
GROUP BY 1, 2, 3
ORDER BY bucket_sort;


/* ----------------------------------------------------------------------------
   Q5_5 — TOP 10 INSURERS BY 90+ DAY UNDISPATCHED AR
   Returns: worst offenders — undispatched invoices aged over 90 days
   Used by: "Most urgent collection targets" table
---------------------------------------------------------------------------- */
SELECT
    insurer_label,
    payer_class,
    SUM(invoice_count)                                                  AS invoices_90plus,
    SUM(outstanding_kes)                                                AS outstanding_90plus_kes,
    MAX(avg_days)                                                       AS avg_age_days
FROM HOSPITALS.REPORTING.rpt_rev_ar_aging
WHERE aging_bucket = '90+ days'
  AND ar_state = 'Undispatched — Claim Not Sent'
GROUP BY 1, 2
ORDER BY outstanding_90plus_kes DESC
LIMIT 10;


/* ----------------------------------------------------------------------------
   Q5_6 — TWO-CLOCK ACCOUNTABILITY SPLIT
   Returns: one row per insurer — billing team delay vs insurer delay
   Used by: accountability chart (our delay vs insurer delay)
---------------------------------------------------------------------------- */
SELECT
    insurer_label,
    payer_class,
    -- Billing team clock: avg days from invoice creation to dispatch submission
    MAX(CASE WHEN ar_state = 'Dispatched — Awaiting Payment'
             THEN avg_days_to_dispatch END)                            AS median_days_to_dispatch,
    -- Insurer clock: avg days since dispatch with no payment
    MAX(CASE WHEN ar_state = 'Dispatched — Awaiting Payment'
             THEN avg_days_outstanding END)                            AS median_days_since_dispatch,
    -- Undispatched exposure
    SUM(CASE WHEN ar_state = 'Undispatched — Claim Not Sent'
             THEN outstanding_kes ELSE 0 END)                          AS undispatched_kes,
    SUM(CASE WHEN ar_state = 'Dispatched — Awaiting Payment'
             THEN outstanding_kes ELSE 0 END)                          AS dispatched_kes,
    SUM(open_invoices)                                                  AS total_open_invoices
FROM HOSPITALS.REPORTING.rpt_rev_ar_snapshot
WHERE insurer_label != '⚠ Unknown (NULL company_id)'
GROUP BY 1, 2
ORDER BY dispatched_kes DESC NULLS LAST;


/* ----------------------------------------------------------------------------
   Q5_7 — DISPATCH RATE TREND (monthly — is it improving?)
   Returns: one row per month — dispatch rate over time
   Used by: dispatch rate trend line showing the Sept 2025 collapse
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    SUM(invoice_count)                                                  AS total_insurer_invoices,
    SUM(dispatched_count)                                               AS dispatched,
    SUM(undispatched_count)                                             AS undispatched,
    ROUND(SUM(dispatched_count) * 100.0
          / NULLIF(SUM(invoice_count), 0), 1)                          AS dispatch_rate_pct,
    SUM(undispatched)                                                   AS undispatched_kes
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE for_cash = 0
GROUP BY 1
ORDER BY 1;


/* ----------------------------------------------------------------------------
   Q5_8 — NULL COMPANY_ID BLIND SPOT DETAIL
   Returns: monthly breakdown of the unknown insurer AR
   Used by: data quality callout banner on AR tab
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    invoice_count,
    invoiced                                                            AS blind_spot_kes,
    undispatched                                                        AS undispatched_kes
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE payer_label = '⚠ Unknown (NULL company_id)'
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q5_9 — AR CONCENTRATION RISK
   Returns: how many insurers account for 80% of open AR
   Used by: concentration risk insight text
---------------------------------------------------------------------------- */
WITH insurer_ar AS (
    SELECT
        insurer_label,
        SUM(outstanding_kes)                                            AS total_ar,
        SUM(SUM(outstanding_kes)) OVER ()                              AS grand_total_ar,
        SUM(SUM(outstanding_kes)) OVER (
            ORDER BY SUM(outstanding_kes) DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                               AS cumulative_ar,
        ROW_NUMBER() OVER (ORDER BY SUM(outstanding_kes) DESC)         AS rank
    FROM HOSPITALS.REPORTING.rpt_rev_ar_snapshot
    GROUP BY 1
)
SELECT
    insurer_label,
    rank,
    total_ar,
    ROUND(total_ar / NULLIF(grand_total_ar, 0) * 100, 2)               AS pct_of_ar,
    ROUND(cumulative_ar / NULLIF(grand_total_ar, 0) * 100, 2)          AS cumulative_pct
FROM insurer_ar
ORDER BY rank;