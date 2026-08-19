/* ============================================================================
   TAB 7 — DATA QUALITY
   Source tables: rpt_rev_data_quality, rpt_rev_monthly_summary,
                  rpt_rev_payer_monthly, rpt_rev_collections_monthly
   Questions answered:
     - What is excluded and why (October 2025, outliers)?
     - How much AR has no insurer identified, and when did it start?
     - What share of billing items have no service line classification?
     - How large is the payment data completeness gap?
     - Which months have 0% dispatch rate — structural vs data gap?
     - What should we trust vs caveat in the dashboard?
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q7_1 — ALL DATA QUALITY FLAGS (full table)
   Returns: all metric rows from the DQ snapshot table
   Used by: main DQ summary table
---------------------------------------------------------------------------- */
SELECT
    metric,
    value,
    unit,
    snapshot_date
FROM HOSPITALS.REPORTING.rpt_rev_data_quality
ORDER BY metric;


/* ----------------------------------------------------------------------------
   Q7_2 — OCTOBER 2025 EXCLUSION IMPACT
   Returns: the two October 2025 rows — invoice count and KES excluded
   Used by: October 2025 callout banner
---------------------------------------------------------------------------- */
SELECT
    metric,
    value,
    unit
FROM HOSPITALS.REPORTING.rpt_rev_data_quality
WHERE metric LIKE 'October 2025%'
ORDER BY metric;


/* ----------------------------------------------------------------------------
   Q7_3 — NULL COMPANY_ID BLIND SPOT OVER TIME
   Returns: monthly trend of unknown insurer AR
   Used by: "When did the blind spot start?" trend chart
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    invoice_count,
    invoiced                                                            AS blind_spot_kes,
    undispatched                                                        AS undispatched_kes,
    ROUND(invoiced
          / NULLIF(SUM(invoiced) OVER (PARTITION BY rev_month), 0) * 100, 1)
                                                                        AS pct_of_month_insurer_ar
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE payer_label = '⚠ Unknown (NULL company_id)'
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q7_4 — DISPATCH ZERO MONTHS DETAIL
   Returns: months with 0% dispatch rate + their invoiced value
   Used by: "Months with no dispatch activity" timeline
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    SUM(invoice_count)                                                  AS insurer_invoices,
    SUM(invoiced)                                                       AS insurer_invoiced_kes,
    SUM(dispatched_count)                                               AS dispatched,
    ROUND(SUM(dispatched_count) * 100.0
          / NULLIF(SUM(invoice_count), 0), 1)                          AS dispatch_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE for_cash = 0
GROUP BY 1
HAVING SUM(dispatched_count) = 0
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q7_5 — PAYMENT RECONCILIATION GAP TREND
   Returns: monthly total_collected vs channel_sum gap
   Used by: payment completeness trend chart
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_collected                                                     AS channel_sum_total,
    total_invoiced,
    ROUND(total_collected / NULLIF(total_invoiced, 0) * 100, 1)       AS collection_rate_pct,
    payment_count
FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q7_6 — UNCLASSIFIED BILLING ITEMS BY MONTH
   Returns: months where unclassified item_type_clean is highest
   Used by: classification gap trend
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    SUM(CASE WHEN service_line = 'Unclassified' THEN revenue ELSE 0 END)
                                                                        AS unclassified_revenue,
    SUM(revenue)                                                        AS total_revenue,
    ROUND(SUM(CASE WHEN service_line = 'Unclassified' THEN revenue ELSE 0 END)
          / NULLIF(SUM(revenue), 0) * 100, 1)                          AS unclassified_pct,
    SUM(CASE WHEN service_line = 'Unclassified' THEN line_items ELSE 0 END)
                                                                        AS unclassified_rows,
    SUM(line_items)                                                     AS total_rows
FROM HOSPITALS.REPORTING.rpt_rev_service_line_monthly
GROUP BY 1
ORDER BY 1;


/* ----------------------------------------------------------------------------
   Q7_7 — DATA TRUST SUMMARY (what to caveat in dashboard)
   Returns: structured list of known caveats with severity
   Used by: "What should we trust?" guidance panel for analytics team
   This is a static reference query — values are hardcoded from known issues.
---------------------------------------------------------------------------- */
SELECT *
FROM (VALUES
    ('HIGH',   'Collection Rate',
     'Same-month join understates recent months — collections still in-flight for invoices < 60 days old'),
    ('HIGH',   'Theatre Billing Capture',
     'IS_BILLED depends on stg_theatre.visit_id coverage — confirm population before presenting billing_capture_rate_pct'),
    ('HIGH',   'October 2025',
     'October 2025 excluded from all trend tables — artificial gap will appear in any unfiltered query'),
    ('HIGH',   'Dispatch Rate Sept 2025 onward',
     '0% dispatch rate from September 2025 — operational failure, not a data gap. Do not impute or smooth.'),
    ('MEDIUM', 'Payment Channel Sum vs Total Collected',
     'KES 64M gap between total_collected and channel_sum — payment data sync incomplete. Use channel_sum as floor.'),
    ('MEDIUM', 'Unknown Insurer AR (NULL company_id)',
     'KES 22M insurer AR with no insurer identified — started June 2025. Cannot be aged by insurer.'),
    ('MEDIUM', 'Pharmacy Leakage — March 2025',
     'Nutriflex outlier (KES 21M, 2 events) inflates leakage_kes. Use leakage_kes_excl_outlier for clean trend.'),
    ('MEDIUM', 'Doctor Name Normalisation',
     'Duplicate doctor entries (case variants) inflate doctor-level unfilled counts. Fix before using Q6_5.'),
    ('LOW',    'Unclassified Billing Items',
     'Up to 17% of billing item revenue in some months has no item_type_clean — mostly PAYMENT_DETAIL stream rows.'),
    ('LOW',    'Patient Value Table',
     'rpt_rev_patient_value only includes patients with stg_payments records. Invoice-only patients excluded.')
) AS caveats(severity, metric_affected, description)
ORDER BY
    CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    metric_affected;