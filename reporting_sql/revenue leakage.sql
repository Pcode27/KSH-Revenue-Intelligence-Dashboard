-- Revenue Leakage tab queries for prescription and billing leakage analysis
-- Co-authored with CoCo
/* ============================================================================
   TAB 6 — REVENUE LEAKAGE
   Source tables: rpt_rev_leakage_summary, rpt_rev_prescription_leakage,
                  rpt_rev_theatre_funnel, rpt_rev_top_items
   Questions answered:
     - What is total recoverable leakage (all 6 vectors)?
     - Which leakage vector is largest?
     - Which drugs account for most pharmacy leakage?
     - Which doctors have the highest unfilled prescription rate?
     - Is leakage worsening month over month?
     - What is the theatre completion and billing capture rate?
     - Which theatre bookings were rejected and why?
     - How many consultations are unbilled?
   NOTE: March 2025 Nutriflex outlier (KES 21M) — two versions shown
         where relevant (with / without outlier). Toggle handled in dashboard.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q6_1 — LEAKAGE RADAR SUMMARY (all 6 vectors)
   Returns: one row per leakage vector with % share
   Used by: Leakage Radar headline, ranked bar, donut
---------------------------------------------------------------------------- */
SELECT
    leakage_vector,
    event_count,
    leakage_kes,
    ROUND(leakage_kes
          / NULLIF(SUM(leakage_kes) OVER (), 0) * 100, 1)             AS pct_of_total_leakage,
    snapshot_date
FROM HOSPITALS.REPORTING.rpt_rev_leakage_summary
WHERE leakage_kes IS NOT NULL
ORDER BY leakage_kes DESC;



/* ----------------------------------------------------------------------------
   Q6_2 — TOTAL LEAKAGE KPI (single number for headline tile)
   Returns: total recoverable leakage in KES, count of vectors with KES value
---------------------------------------------------------------------------- */
/* ----------------------------------------------------------------------------
   Q6_2 — TOTAL LEAKAGE KPI (single number for headline tile)
   Measures: the total recoverable leakage exposure across all 6 vectors,
   based on current open balances (not a historical period).
   - Undispatched AR and NULL company_id AR reflect today's open balance
   - Pharmacy leakage reflects all unfilled prescriptions in the data
   - snapshot_date = max invoice date in the data, not CURRENT_DATE,
     since data only runs to April 2026
---------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                                            AS total_vectors,
    COUNT(leakage_kes)                                                  AS vectors_with_kes_value,
    SUM(leakage_kes)                                                    AS total_leakage_kes,
    -- Use max invoice date as reference, not CURRENT_DATE
    (SELECT MAX(invoice_date)::DATE FROM HOSPITALS.STAGING.STG_INVOICES) AS data_through_date
FROM HOSPITALS.REPORTING.rpt_rev_leakage_summary;

/* ----------------------------------------------------------------------------
   Q6_3 — PHARMACY LEAKAGE TREND (monthly)
   Returns: one row per month — leakage count, KES with and without outlier
   Used by: "Is leakage worsening?" trend line
---------------------------------------------------------------------------- */
SELECT
    prescription_month,
    SUM(leakage_count)                                                  AS leakage_events,
    SUM(leakage_kes)                                                    AS leakage_kes_incl_outlier,
    SUM(leakage_kes_excl_outlier)                                       AS leakage_kes_excl_outlier,
    SUM(total_prescriptions)                                            AS total_prescriptions,
    SUM(total_pharmacy_kes)                                             AS total_pharmacy_kes,
    ROUND(SUM(leakage_count) * 100.0
          / NULLIF(SUM(total_prescriptions), 0), 1)                    AS leakage_rate_pct,
    ROUND(SUM(leakage_kes_excl_outlier) * 100.0
          / NULLIF(SUM(total_pharmacy_kes) - SUM(leakage_kes) + SUM(leakage_kes_excl_outlier), 0), 1)
                                                                        AS leakage_rate_pct_excl_outlier,
    MAX(CASE WHEN contains_outlier THEN TRUE ELSE FALSE END)            AS month_has_outlier
FROM HOSPITALS.REPORTING.rpt_rev_prescription_leakage
GROUP BY 1
ORDER BY 1;


/* ----------------------------------------------------------------------------
   Q6_4 — TOP 30 DRUGS BY LEAKAGE VALUE
   Returns: one row per drug, ranked by leakage KES (excl. outlier)
   Used by: drug drill-down ranked table
---------------------------------------------------------------------------- */
SELECT
    drug_name,
    store_name,
    SUM(leakage_count)                                                  AS leakage_events,
    SUM(leakage_kes_excl_outlier)                                       AS leakage_kes,
    SUM(total_prescriptions)                                            AS total_prescriptions,
    ROUND(SUM(leakage_count) * 100.0
          / NULLIF(SUM(total_prescriptions), 0), 1)                    AS leakage_rate_pct,
    ROUND(SUM(leakage_kes_excl_outlier)
          / NULLIF(SUM(leakage_count), 0), 0)                          AS avg_leakage_per_event
FROM HOSPITALS.REPORTING.rpt_rev_prescription_leakage
GROUP BY 1, 2
ORDER BY leakage_kes DESC
LIMIT 30;


/* ----------------------------------------------------------------------------
   Q6_5 — DOCTOR LEAKAGE ACCOUNTABILITY (top 20 by unfilled KES)
   Returns: one row per doctor — prescriptions written, unfilled count, KES
   Used by: doctor accountability table
   NOTE: Doctor names need normalisation (Dr. CHRISTINE ATOLO vs Dr. Christine Atolo)
         — results may show duplicates until that is fixed in the source
---------------------------------------------------------------------------- */
SELECT
    prescribed_by,
    SUM(total_prescriptions)                                            AS prescriptions_written,
    SUM(leakage_count)                                                  AS unfilled_count,
    SUM(leakage_kes_excl_outlier)                                       AS unfilled_kes,
    ROUND(SUM(leakage_count) * 100.0
          / NULLIF(SUM(total_prescriptions), 0), 1)                    AS unfilled_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_prescription_leakage
WHERE prescribed_by IS NOT NULL
GROUP BY 1
HAVING SUM(total_prescriptions) >= 10   -- exclude low-volume prescribers
ORDER BY unfilled_kes DESC
LIMIT 20;


/* ----------------------------------------------------------------------------
   Q6_6 — PRESCRIPTION FULFILLMENT STATUS BREAKDOWN
   Returns: dispensed / cancelled / leakage / filled-then-cancelled counts
   Used by: fulfillment status donut
---------------------------------------------------------------------------- */
SELECT
    SUM(dispensed_count)                                                AS dispensed,
    SUM(cancelled_count)                                                AS cancelled_not_leakage,
    SUM(filled_then_cancelled)                                          AS filled_then_cancelled,
    SUM(leakage_count)                                                  AS leakage_unfilled,
    SUM(total_prescriptions)                                            AS total,
    ROUND(SUM(leakage_count) * 100.0
          / NULLIF(SUM(total_prescriptions), 0), 1)                    AS overall_leakage_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_prescription_leakage;


/* ----------------------------------------------------------------------------
   Q6_7 — THEATRE BOOKING FUNNEL (monthly)
   Returns: one row per booking_month × status × completion × billing
   Used by: theatre funnel chart
---------------------------------------------------------------------------- */
SELECT
    booking_month,
    booking_status,
    is_scheduled,
    has_operation,
    is_billed,
    booking_count,
    expected_revenue_kes,
    completed_revenue_kes,
    incomplete_revenue_kes,
    completed_unbilled_kes,
    actual_billed_kes,
    completion_rate_pct,
    billing_capture_rate_pct,
    reason_summary
FROM HOSPITALS.REPORTING.rpt_rev_theatre_funnel
ORDER BY booking_month DESC, expected_revenue_kes DESC;


/* ----------------------------------------------------------------------------
   Q6_8 — THEATRE FUNNEL SUMMARY (overall — all time)
   Returns: funnel KPIs in one row
   Used by: theatre leakage headline KPIs
---------------------------------------------------------------------------- */
SELECT
    SUM(booking_count)                                                  AS total_bookings,
    SUM(CASE WHEN has_operation THEN booking_count ELSE 0 END)          AS completed_bookings,
    SUM(CASE WHEN has_operation AND is_billed THEN booking_count ELSE 0 END) AS billed_bookings,
    SUM(CASE WHEN has_operation AND NOT is_billed
             THEN booking_count ELSE 0 END)                            AS completed_unbilled_count,
    SUM(expected_revenue_kes)                                           AS total_expected_kes,
    SUM(completed_revenue_kes)                                          AS total_completed_kes,
    SUM(completed_unbilled_kes)                                         AS total_unbilled_kes,
    ROUND(SUM(CASE WHEN has_operation THEN booking_count ELSE 0 END)
          * 100.0 / NULLIF(SUM(booking_count), 0), 1)                  AS overall_completion_rate_pct,
    ROUND(SUM(CASE WHEN has_operation AND is_billed THEN booking_count ELSE 0 END)
          * 100.0 / NULLIF(
              SUM(CASE WHEN has_operation THEN booking_count ELSE 0 END), 0
          ), 1)                                                         AS overall_billing_capture_pct
FROM HOSPITALS.REPORTING.rpt_rev_theatre_funnel;


/* ----------------------------------------------------------------------------
   Q6_9 — REJECTED THEATRE BOOKINGS (lost revenue by reason)
   Returns: rejected and unscheduled bookings with reasons
   Used by: "Lost theatre revenue" table
---------------------------------------------------------------------------- */
SELECT
    booking_month,
    booking_status,
    reason_summary,
    booking_count,
    expected_revenue_kes                                                AS lost_revenue_kes
FROM HOSPITALS.REPORTING.rpt_rev_theatre_funnel
WHERE booking_status = 'rejected'
   OR (booking_status = 'booked' AND has_operation = FALSE AND is_scheduled = FALSE)
ORDER BY lost_revenue_kes DESC;


/* ----------------------------------------------------------------------------
   Q6_10 — UNBILLED CONSULTATIONS SUMMARY
   Returns: pulled directly from leakage summary (event count only — no KES)
   Used by: unbilled consultation KPI tile with caveat label
---------------------------------------------------------------------------- */
SELECT
    leakage_vector,
    event_count                                                         AS unbilled_encounter_count,
    'No tariff in data — KES value not computable'                      AS kes_note,
    snapshot_date
FROM HOSPITALS.REPORTING.rpt_rev_leakage_summary
WHERE leakage_vector = 'Unbilled Consultations';


/* ----------------------------------------------------------------------------
   Q6_11 — OUTLIER DISCLOSURE (March 2025 Nutriflex)
   Returns: the excluded outlier rows for explicit disclosure in the dashboard
   Used by: outlier callout banner on pharmacy leakage section
---------------------------------------------------------------------------- */
SELECT
    prescription_month,
    drug_name,
    prescribed_by,
    leakage_count,
    leakage_kes                                                         AS leakage_kes_incl_outlier,
    leakage_kes_excl_outlier,
    leakage_kes - leakage_kes_excl_outlier                             AS outlier_value_kes,
    contains_outlier
FROM HOSPITALS.REPORTING.rpt_rev_prescription_leakage
WHERE contains_outlier = TRUE
ORDER BY outlier_value_kes DESC;