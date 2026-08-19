/* ============================================================================
   TAB 3 — PAYER & PATIENT MIX
   Source tables: rpt_rev_payer_monthly, rpt_rev_patient_value,
                  rpt_rev_monthly_summary
   Questions answered:
     - What is the cash vs insurer split and how is it trending?
     - Which insurers are we most dependent on (concentration risk)?
     - How is SHA's share growing over time?
     - Which patients generate the most revenue (Pareto)?
     - What is ARPU by payer type and over time?
     - Patient clustering by recency and value (RFM-style)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q3_1 — PAYER TYPE SPLIT TREND (monthly)
   Returns: one row per month — cash vs insurer totals
   Used by: trend chart showing payer mix shift over time
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    SUM(CASE WHEN for_cash = 1 THEN invoiced ELSE 0 END)               AS cash_invoiced,
    SUM(CASE WHEN for_cash = 0 THEN invoiced ELSE 0 END)               AS insurer_invoiced,
    SUM(invoiced)                                                       AS total_invoiced,
    ROUND(SUM(CASE WHEN for_cash = 0 THEN invoiced ELSE 0 END)
          / NULLIF(SUM(invoiced), 0) * 100, 1)                         AS insurer_pct
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
GROUP BY 1
ORDER BY 1;



/* ----------------------------------------------------------------------------
   Q3_2 — PAYER CLASS BREAKDOWN (current month)
   Returns: one row per payer_class — SHA, private insurer, corporate, cash
   Used by: payer class donut / bar
---------------------------------------------------------------------------- */
SELECT
    payer_class,
    SUM(invoice_count)                                                  AS invoices,
    SUM(invoiced)                                                       AS invoiced_kes,
    ROUND(SUM(invoiced)
          / NULLIF(SUM(SUM(invoiced)) OVER (), 0) * 100, 1)            AS pct_of_total
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE rev_month = (SELECT MAX(rev_month) FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly)
GROUP BY 1
ORDER BY invoiced_kes DESC;


/* ----------------------------------------------------------------------------
   Q3_3 — INSURER CONCENTRATION PARETO (all-time)
   Returns: one row per insurer sorted by total invoiced, with cumulative %
   Used by: Pareto concentration chart
---------------------------------------------------------------------------- */
WITH insurer_totals AS (
    SELECT
        payer_label,
        payer_class,
        SUM(invoiced)                                                   AS total_invoiced,
        SUM(dispatched)                                                 AS total_dispatched,
        SUM(undispatched)                                               AS total_undispatched,
        ROUND(SUM(dispatched_count) * 100.0
              / NULLIF(SUM(invoice_count), 0), 1)                      AS overall_dispatch_rate_pct
    FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
    WHERE for_cash = 0
    GROUP BY 1, 2
)
SELECT
    payer_label,
    payer_class,
    total_invoiced,
    total_dispatched,
    total_undispatched,
    overall_dispatch_rate_pct,
    ROUND(total_invoiced
          / NULLIF(SUM(total_invoiced) OVER (), 0) * 100, 2)           AS pct_of_insurer_total,
    ROUND(SUM(total_invoiced) OVER (
        ORDER BY total_invoiced DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / NULLIF(SUM(total_invoiced) OVER (), 0) * 100, 2)               AS cumulative_pct
FROM insurer_totals
ORDER BY total_invoiced DESC;


/* ----------------------------------------------------------------------------
   Q3_4 — SHA GROWTH TRAJECTORY (monthly)
   Returns: SHA invoiced vs all insurer invoiced by month
   Used by: "Is SHA dependence growing?" trend line
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    SUM(CASE WHEN payer_label LIKE '%SHA%'
               OR payer_label LIKE '%Social Health%'
             THEN invoiced ELSE 0 END)                                  AS sha_invoiced,
    SUM(CASE WHEN payer_label LIKE '%NHIF%'
             THEN invoiced ELSE 0 END)                                  AS nhif_invoiced,
    SUM(invoiced)                                                       AS total_insurer_invoiced,
    ROUND(SUM(CASE WHEN payer_label LIKE '%SHA%'
                     OR payer_label LIKE '%Social Health%'
                   THEN invoiced ELSE 0 END)
          / NULLIF(SUM(invoiced), 0) * 100, 1)                         AS sha_pct_of_insurer
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE for_cash = 0
GROUP BY 1
ORDER BY 1;


/* ----------------------------------------------------------------------------
   Q3_5 — INSURER DISPATCH PERFORMANCE (all-time, sorted by worst)
   Returns: one row per insurer — dispatch rate and undispatched exposure
   Used by: dispatch performance table on payer mix tab
---------------------------------------------------------------------------- */
SELECT
    payer_label,
    payer_class,
    SUM(invoice_count)                                                  AS total_invoices,
    SUM(invoiced)                                                       AS total_invoiced,
    SUM(undispatched)                                                   AS undispatched_kes,
    SUM(dispatched)                                                     AS dispatched_kes,
    ROUND(SUM(dispatched_count) * 100.0
          / NULLIF(SUM(invoice_count), 0), 1)                          AS dispatch_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_payer_monthly
WHERE for_cash = 0
GROUP BY 1, 2
ORDER BY dispatch_rate_pct ASC;


/* ----------------------------------------------------------------------------
   Q3_6 — ARPU TREND (monthly — invoiced and collected)
   Returns: one row per month
   Used by: ARPU over time line chart
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    unique_patients,
    arpu_invoiced,
    arpu_collected,
    total_invoiced,
    total_collected,
    -- Rolling 3-month ARPU
    ROUND(AVG(arpu_invoiced) OVER (
        ORDER BY rev_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 0)                                                               AS arpu_rolling_3m
FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q3_7 — PATIENT PARETO (top 100 patients by lifetime collected)
   Returns: one row per patient, top 100
   Used by: patient value ranked table, Pareto curve
---------------------------------------------------------------------------- */
SELECT
    patient_id,
    payment_events,
    total_collected,
    total_invoiced,
    invoice_count,
    active_months,
    first_payment_date,
    last_payment_date,
    avg_monthly_collected,
    cumulative_pct_collected,
    days_since_last_payment
FROM HOSPITALS.REPORTING.rpt_rev_patient_value
ORDER BY total_collected DESC
LIMIT 100;


/* ----------------------------------------------------------------------------
   Q3_8 — PATIENT PARETO CURVE (what % of patients = 80% of revenue)
   Returns: breakpoints for 50%, 70%, 80%, 90% of total collected
   Used by: Pareto insight text ("Top X% of patients = 80% of revenue")
---------------------------------------------------------------------------- */
WITH ranked AS (
    SELECT
        patient_id,
        total_collected,
        cumulative_pct_collected,
        ROW_NUMBER() OVER (ORDER BY total_collected DESC)               AS patient_rank,
        COUNT(*) OVER ()                                                AS total_patients
    FROM HOSPITALS.REPORTING.rpt_rev_patient_value
    WHERE total_collected > 0
)
SELECT
    threshold,
    MIN(patient_rank)                                                   AS patients_needed,
    MIN(total_patients)                                                 AS total_patients,
    ROUND(MIN(patient_rank) * 100.0 / MIN(total_patients), 1)          AS pct_of_patients
FROM ranked
CROSS JOIN (
    SELECT 50 AS threshold UNION ALL SELECT 70
    UNION ALL SELECT 80    UNION ALL SELECT 90
) thresholds
WHERE cumulative_pct_collected >= threshold
GROUP BY threshold
ORDER BY threshold;


/* ----------------------------------------------------------------------------
   Q3_9 — PATIENT CLUSTERING (RFM-style segmentation)
   Returns: one row per patient with segment label
   Segments: Champions, Loyal, At Risk, Lost
   Used by: patient cluster breakdown chart
---------------------------------------------------------------------------- */
SELECT
    patient_id,
    total_collected,
    active_months,
    days_since_last_payment,
    avg_monthly_collected,
    -- RFM-style segment
    CASE
        WHEN days_since_last_payment <= 90  AND total_collected >= 10000 THEN 'Champion'
        WHEN days_since_last_payment <= 180 AND total_collected >= 5000  THEN 'Loyal'
        WHEN days_since_last_payment BETWEEN 91 AND 270                  THEN 'At Risk'
        WHEN days_since_last_payment > 270                               THEN 'Lost'
        ELSE 'New / Low Value'
    END                                                                 AS patient_segment
FROM HOSPITALS.REPORTING.rpt_rev_patient_value
ORDER BY total_collected DESC;


/* ----------------------------------------------------------------------------
   Q3_10 — PATIENT SEGMENT SUMMARY
   Returns: one row per segment — count, total revenue, avg value
   Used by: segment summary tiles
---------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN days_since_last_payment <= 90  AND total_collected >= 10000 THEN 'Champion'
        WHEN days_since_last_payment <= 180 AND total_collected >= 5000  THEN 'Loyal'
        WHEN days_since_last_payment BETWEEN 91 AND 270                  THEN 'At Risk'
        WHEN days_since_last_payment > 270                               THEN 'Lost'
        ELSE 'New / Low Value'
    END                                                                 AS patient_segment,
    COUNT(*)                                                            AS patient_count,
    SUM(total_collected)                                                AS total_collected,
    ROUND(AVG(total_collected), 0)                                      AS avg_collected,
    ROUND(AVG(active_months), 1)                                        AS avg_active_months,
    ROUND(SUM(total_collected)
          / NULLIF(SUM(SUM(total_collected)) OVER (), 0) * 100, 1)     AS pct_of_total_revenue
FROM HOSPITALS.REPORTING.rpt_rev_patient_value
GROUP BY 1
ORDER BY total_collected DESC;