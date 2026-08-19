/* ============================================================================
   TAB 4 — COLLECTIONS & CHANNELS
   Source tables: rpt_rev_collections_monthly, rpt_rev_monthly_summary,
                  rpt_rev_ar_snapshot
   Questions answered:
     - What is the collection rate by month?
     - How has payment channel mix shifted over time?
     - When did cash disappear as a payment mode?
     - What is DSO — billing team delay vs insurer delay?
     - Are waivers and discounts material?
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Q4_1 — COLLECTION RATE TREND (monthly)
   Returns: one row per month — invoiced, collected, rate
   Used by: collection rate line chart
   NOTE: same-month join — label recent months as "incomplete" using the flag
---------------------------------------------------------------------------- */
SELECT
    c.rev_month,
    c.total_invoiced,
    c.total_collected,
    c.collection_rate_pct,
    -- Flag: collection still in-flight for months < 60 days old
    CASE
        WHEN c.rev_month >= DATEADD('month', -2, DATE_TRUNC('month', CURRENT_DATE)::DATE)
        THEN TRUE ELSE FALSE
    END                                                                 AS collection_incomplete_flag,
    c.mom_collected_delta,
    -- Rolling 3-month collection rate
    ROUND(AVG(c.collection_rate_pct) OVER (
        ORDER BY c.rev_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 1)                                                               AS rolling_3m_collection_rate
FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly c
ORDER BY c.rev_month;


/* ----------------------------------------------------------------------------
   Q4_2 — PAYMENT CHANNEL MIX TREND (monthly, absolute KES)
   Returns: one row per month with each channel as a column
   Used by: stacked bar / area chart of channel mix
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_collected,
    cash,
    mpesa,
    card,
    pesapal,
    cheque,
    patient_account,
    -- Channel %
    cash_pct,
    mpesa_pct,
    card_pct,
    pesapal_pct,
    -- PesaPal is the combined M-Pesa + Card via PesaPal gateway
    ROUND((pesapal / NULLIF(total_collected, 0)) * 100, 1)             AS pesapal_pct_raw
FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q4_3 — CHANNEL MIX 100% STACKED (for proportional chart)
   Returns: long format — one row per month × channel
   Used by: 100% stacked bar showing channel share shift
---------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT
        rev_month,
        total_collected,
        cash,
        mpesa,
        card,
        pesapal,
        cheque,
        patient_account
    FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
    WHERE total_collected > 0
)
SELECT rev_month, 'Cash'           AS channel, cash           AS amount,
       ROUND(cash           / NULLIF(total_collected, 0) * 100, 1) AS pct FROM monthly
UNION ALL
SELECT rev_month, 'M-Pesa',        mpesa,
       ROUND(mpesa          / NULLIF(total_collected, 0) * 100, 1) FROM monthly
UNION ALL
SELECT rev_month, 'Card',          card,
       ROUND(card           / NULLIF(total_collected, 0) * 100, 1) FROM monthly
UNION ALL
SELECT rev_month, 'PesaPal',       pesapal,
       ROUND(pesapal        / NULLIF(total_collected, 0) * 100, 1) FROM monthly
UNION ALL
SELECT rev_month, 'Cheque',        cheque,
       ROUND(cheque         / NULLIF(total_collected, 0) * 100, 1) FROM monthly
UNION ALL
SELECT rev_month, 'Patient Account', patient_account,
       ROUND(patient_account / NULLIF(total_collected, 0) * 100, 1) FROM monthly
ORDER BY rev_month, pct DESC;


/* ----------------------------------------------------------------------------
   Q4_4 — CASH DISAPPEARANCE POINT
   Returns: the month cash dropped below 1% of collections
   Used by: "When did cash disappear?" insight text
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    cash,
    total_collected,
    cash_pct,
    CASE WHEN cash_pct < 1.0 THEN TRUE ELSE FALSE END                  AS cash_below_1pct
FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
WHERE cash_pct IS NOT NULL
ORDER BY rev_month;



/* ----------------------------------------------------------------------------
   Q4_5 — WAIVER AND DISCOUNT ANALYSIS (monthly)
   Returns: one row per month — waiver and discount totals
   Used by: concession rate trend, revenue integrity check
---------------------------------------------------------------------------- */
SELECT
    rev_month,
    total_collected,
    total_waived,
    total_discounted,
    total_waived + total_discounted                                     AS total_concessions,
    waiver_payment_count,
    ROUND((total_waived + total_discounted)
          / NULLIF(total_collected + total_waived + total_discounted, 0) * 100, 1)
                                                                        AS concession_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
-- Note: all months may show zero waivers and discounts — this is a data finding,
-- not a filter gap. The waiver/discount fields may not be populated in the source.
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q4_6 — DSO — CASH SIDE (days from invoice to payment for cash invoices)
   Method: DSO = (open AR / monthly revenue) × days in period
   Returns: monthly DSO estimate for cash side
   Used by: DSO trend chart
   NOTE: Insurer DSO is in Tab 5 (AR tab) — it's measured differently
---------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT
        rev_month,
        total_invoiced,
        total_collected,
        -- Days in the month
        DATEDIFF('day', rev_month, DATEADD('month', 1, rev_month))     AS days_in_month,
        -- Estimate of outstanding cash receivable (invoiced - collected, floor at 0)
        GREATEST(total_invoiced - total_collected, 0)                  AS est_cash_ar
    FROM HOSPITALS.REPORTING.rpt_rev_collections_monthly
    WHERE total_invoiced > 0
)
SELECT
    rev_month,
    total_invoiced,
    total_collected,
    est_cash_ar,
    days_in_month,
    -- DSO formula: (AR / Revenue) × Days
    ROUND(est_cash_ar / NULLIF(total_invoiced, 0) * days_in_month, 1) AS dso_days,
    -- Rolling 3-month DSO
    ROUND(AVG(
        est_cash_ar / NULLIF(total_invoiced, 0) * days_in_month
    ) OVER (ORDER BY rev_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)
                                                                        AS dso_rolling_3m
FROM monthly
ORDER BY rev_month;


/* ----------------------------------------------------------------------------
   Q4_7 — DSO — INSURER SIDE (dispatch lag + insurer sitting time)
   Returns: one row per insurer — median days to dispatch + median since dispatch
   Used by: insurer DSO breakdown table (billing team vs insurer accountability)
---------------------------------------------------------------------------- */
SELECT
    insurer_label,
    payer_class,
    ar_state,
    open_invoices,
    outstanding_kes,
    avg_days_outstanding,
    median_days_outstanding,
    avg_days_to_dispatch,
    -- Total DSO components
    CASE
        WHEN ar_state = 'Undispatched — Claim Not Sent'
        THEN 'Billing team delay'
        ELSE 'Insurer delay'
    END                                                                 AS delay_owner
FROM HOSPITALS.REPORTING.rpt_rev_ar_snapshot
ORDER BY outstanding_kes DESC;


/* ----------------------------------------------------------------------------
   Q4_8 — COLLECTION RATE BY PAYER TYPE (from monthly summary)
   Returns: cash vs insurer collection rates — computed by joining collections
   to payer split from monthly summary
   Used by: payer-segmented collection rate KPI tiles
---------------------------------------------------------------------------- */
SELECT
    m.rev_month,
    m.cash_invoiced,
    m.insurer_invoiced,
    m.total_collected,
    -- Note: collections cannot be split cash/insurer from stg_payments directly
    -- (no payer flag on payment rows). Total rate only is reliable.
    m.collection_rate_pct                                               AS overall_collection_rate_pct,
    m.dispatch_rate_pct                                                 AS insurer_dispatch_rate_pct
FROM HOSPITALS.REPORTING.rpt_rev_monthly_summary m
ORDER BY m.rev_month;