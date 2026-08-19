/* ============================================================================
   KSH REVENUE INTELLIGENCE DASHBOARD — QUERY LAYOUT REFERENCE
   Schema:   HOSPITALS.REPORTING
   Tables:   rpt_rev_* (13 tables)
   Tabs:     7 tabs · 47 queries total
   Audience: Analytics team — describes what each query answers,
             what to expect in results, and where results appear in the UI.

   TAB ORDER:
     Tab 1 — Overview              (Q1_1  – Q1_5)
     Tab 2 — Revenue Pulse         (Q2_1  – Q2_9)
     Tab 3 — Payer & Patient Mix   (Q3_1  – Q3_10)
     Tab 4 — Collections & Channels(Q4_1  – Q4_8)
     Tab 5 — Accounts Receivable   (Q5_1  – Q5_9)
     Tab 6 — Revenue Leakage       (Q6_1  – Q6_11)
     Tab 7 — Data Quality          (Q7_1  – Q7_7)

   GLOBAL RULES:
     - All "current month" queries use MAX(rev_month), not CURRENT_DATE.
       Data ends April 2026. CURRENT_DATE = August 2026 returns nothing.
     - October 2025 excluded from all trend tables — confirmed anomaly.
     - IS_OUTLIER rows excluded from all billing item aggregations.
     - Collection metric = channel_sum, NOT total_collected.

     YOU CAN USE THIS IF YOU FIND IT USEFUL
   ============================================================================ */


-- =============================================================================
-- TAB 1 — OVERVIEW
-- Purpose : 30-second executive read. All KPIs, automated signals, leakage
--           summary, and billing trend. Anchored to latest available month.
-- Audience: CFO, CEO
-- Sources : rpt_rev_monthly_summary, rpt_rev_leakage_summary,
--           rpt_rev_service_line_monthly, rpt_rev_payer_monthly
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q1_1 — KPI TILES
-- Answers  : What are the headline numbers for the latest month vs prior month?
-- UI       : Top KPI tile row — Gross Revenue, Avg Daily Revenue,
--            Collection Rate, Unique Patients, ARPU, Open AR, Dispatch Rate.
-- Returns  : 1 row with current values and MoM deltas.
-- Normal   : Positive MoM deltas, collection rate 6–14%, dispatch rate >60%.
-- Alarming : Negative revenue delta; collection rate <6%; dispatch rate 0%.
-- Note     : Uses MAX(rev_month) anchor — not CURRENT_DATE.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q1_2 — MONTHLY REVENUE TREND
-- Answers  : How has gross revenue trended over the last 13 months?
-- UI       : Sparkline / line chart below the KPI tiles.
-- Returns  : 1 row per month (last 13 months) with rolling 3-month average.
-- Normal   : Upward trend or stable seasonal pattern.
-- Alarming : Rolling average declining for 2+ consecutive months.
-- Note     : Anchored to MAX(rev_month) − 13 months, not CURRENT_DATE.
--            October 2025 absent — correct exclusion, not missing data.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q1_3 — LEAKAGE RADAR SUMMARY
-- Answers  : What are the top recoverable leakage exposures?
-- UI       : Bottom leakage callout tiles — top 3 vectors shown.
-- Returns  : Up to 6 rows (one per leakage vector) ordered by KES exposure.
--            Unbilled Consultations has NULL leakage_kes — no tariff in data.
-- Normal   : Pharmacy leakage largest; credit notes and co-pay small.
-- Alarming : Any vector growing month-on-month.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q1_4 — SIGNAL ENGINE
-- Answers  : Are there any revenue conditions that require immediate attention?
-- UI       : Signals panel — fires coloured alert bars (HIGH=red, MEDIUM=amber).
--            Empty result = no active alerts.
-- Returns  : 0–N rows, one per fired signal.
-- Signals  :
--   1. Revenue trend      — current month >10% below 3-month rolling average
--   2. Dispatch collapse  — dispatch rate <50% of prior 3-month average
--   3. SHA concentration  — SHA >35% of monthly invoiced
--   4. Low collection     — collection rate <8%
--   5. Service line drop  — any line loses >5pp share month-on-month
--   6. Leakage spike      — total leakage exposure >KES 10M
-- Normal   : 0 rows returned.
-- Alarming : Any HIGH severity row — requires same-day investigation.
-- Note     : Uses MAX(rev_month) anchor throughout — not CURRENT_DATE.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q1_5 — PAYER MIX DONUT
-- Answers  : What share of latest month revenue is cash vs insurer?
-- UI       : Small donut chart on Overview — 2 segments.
-- Returns  : 2 rows (Cash, Insurer) with invoiced KES and % of total.
-- Normal   : Insurer 75–87%, Cash 13–25%.
-- Alarming : Insurer above 90% = over-dependence; Cash above 35% = unusual.
-- Note     : Uses MAX(rev_month) anchor — not CURRENT_DATE.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 2 — REVENUE PULSE
-- Purpose : Billing trends, service mix, timing patterns, top items, forecast.
--           Answers what is growing, what is shrinking, when revenue peaks.
-- Audience: Finance team, clinical leads
-- Sources : rpt_rev_monthly_summary, rpt_rev_service_line_monthly,
--           rpt_rev_timing, rpt_rev_top_items
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q2_1 — MONTHLY BILLING TREND
-- Answers  : How is total revenue trending over all time?
-- UI       : Main trend chart — line with rolling averages and MoM delta.
-- Returns  : 1 row per month, all time, with 3-month and 6-month rolling avgs.
-- Normal   : Upward trend; rolling avg smooths month-end spikes.
-- Alarming : Rolling average declining for 2+ months consecutively.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_2 — REVENUE DRIVER DECOMPOSITION
-- Answers  : Is revenue growth coming from more patients or higher billing
--            per patient?
-- UI       : Grouped bar — volume effect vs intensity effect per month.
-- Returns  : 1 row per month with volume_effect_kes and intensity_effect_kes.
--   volume_effect    = change in invoice count × prior avg invoice amount
--   intensity_effect = change in avg invoice amount × prior invoice count
-- Normal   : Positive volume effect = more patients billed.
--            Positive intensity = higher case complexity or tariff increases.
-- Alarming : Both effects negative simultaneously = declining volume and value.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_3 — SERVICE LINE TREND
-- Answers  : How is each service line's revenue evolving month by month?
-- UI       : Stacked area chart — Lab, Inpatient, Pharmacy, Procedure,
--            Consumable, Unclassified.
-- Returns  : 1 row per service_line × month with MoM delta.
-- Normal   : Laboratory ~40–45% share; Inpatient ~15–20%.
-- Alarming : Any line losing >5pp share in a single month.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_4 — SERVICE LINE SHARE SHIFT
-- Answers  : Which service lines have structurally grown or shrunk?
-- UI       : Diverging bar — share shift in percentage points.
-- Returns  : 1 row per service line — current month vs 5 months ago.
--            (6 months back = October 2025 = excluded; 5 months used instead.)
-- Columns  : current_pct, pct_5m_ago, share_shift_pp, revenue_growth_5m_pct.
-- Normal   : Shifts within ±2pp are normal seasonal variation.
-- Alarming : Shift >5pp in either direction — investigate case mix or billing.
-- Note     : Comparison anchor = November 2025 (nearest clean month to −6m).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_5 — REVENUE TIMING — DAY OF WEEK
-- Answers  : Which day of the week generates the most revenue on average?
-- UI       : Bar chart — Mon through Sun with daily_revenue_index (100 = avg).
-- Returns  : 7 rows, one per day, sorted Monday to Sunday.
-- Normal   : Weekdays significantly above 100 index; weekends below.
-- Alarming : Any weekday below index 80 sustained = unexplained low-volume.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_6 — REVENUE TIMING — WEEK OF MONTH
-- Answers  : Which week of the month generates the most revenue?
-- UI       : Bar chart — Week 1 (1–7), Week 2 (8–14), Week 3 (15–21),
--            Week 4 (22+).
-- Returns  : 4 rows with avg_daily_invoiced per week bucket.
-- Normal   : Revenue typically higher in Week 1–2 (early billing cycle).
-- Alarming : Week 4 consistently highest may signal month-end billing rush.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_7 — TOP REVENUE ITEMS
-- Answers  : What are the single highest-earning billing items of all time?
-- UI       : Ranked table — top 30 items by total KES.
-- Returns  : 30 rows with item_name, times_billed, total_revenue, avg_price.
-- Normal   : Laboratory items dominate top positions.
-- Alarming : A top-5 item absent from the last 3 months = discontinued or
--            billing code changed — investigate before next period.
-- Note     : IS_OUTLIER rows excluded. No October 2025 exclusion (all-time).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_8 — TOP ITEMS BY SERVICE LINE
-- Answers  : Within each service line, what drives the most revenue?
-- UI       : Expandable section per service line — top 10 items each.
-- Returns  : 10 rows per service line (ROW_NUMBER within service_line).
-- Normal   : Each line has 1–2 dominant items at 40–60% of line revenue.
-- Alarming : No dominant item = fragmented billing, harder to track leakage.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q2_9 — 90-DAY REVENUE FORECAST
-- Answers  : What is the expected revenue for the next 3 months?
-- UI       : Forecast band extending the main trend chart.
-- Returns  : 3 rows (next 3 months) with forecast_invoiced and flat_baseline.
-- Method   : 6-month rolling average × historical average MoM growth rate.
-- IMPORTANT: Label as "Indicative only" in all dashboard-facing text.
--            Not a regression model. High volatility months reduce reliability.
-- Normal   : Forecast close to flat_baseline = stable, predictable growth.
-- Alarming : Large gap between forecast and baseline = recent high volatility.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 3 — PAYER & PATIENT MIX
-- Purpose : Who pays us, which insurers dominate, patient value distribution,
--           ARPU trends, and patient clustering.
-- Audience: Finance team, strategy
-- Sources : rpt_rev_payer_monthly, rpt_rev_patient_value,
--           rpt_rev_monthly_summary
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q3_1 — PAYER TYPE SPLIT TREND
-- Answers  : How has the cash vs insurer split shifted over time?
-- UI       : Stacked area chart — cash_invoiced vs insurer_invoiced monthly.
-- Returns  : 1 row per month with both amounts and insurer_pct.
-- Normal   : Insurer 75–87% of monthly total.
-- Alarming : Insurer below 65% = unusual shift to cash. Above 90% = risk.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_2 — PAYER CLASS BREAKDOWN
-- Answers  : In the latest month, what is the revenue share by payer category?
-- UI       : Donut or bar chart — SHA, private insurer, corporate, cash.
-- Returns  : 1 row per payer_class with invoiced KES and pct_of_total.
-- Normal   : SHA + NHIF combined 30–35% of insurer total.
-- Alarming : SHA alone above 35% of total invoiced = concentration risk.
-- Note     : Uses MAX(rev_month) — not CURRENT_DATE.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_3 — INSURER CONCENTRATION PARETO
-- Answers  : How concentrated is insurer revenue across payers?
-- UI       : Pareto bar + cumulative line chart.
-- Returns  : 1 row per insurer with total_invoiced and cumulative_pct.
-- Normal   : Top 5–8 insurers account for ~80% of insurer AR.
-- Alarming : Top 2–3 insurers alone = 80% of AR = extreme concentration risk.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_4 — SHA GROWTH TRAJECTORY
-- Answers  : Is SHA's share of insurer revenue growing over time?
-- UI       : Line chart — SHA % of insurer invoiced by month.
-- Returns  : 1 row per month with sha_invoiced and sha_pct_of_insurer.
-- Normal   : SHA growing as government coverage expands under UHC.
-- Alarming : SHA declining = patients shifting away from SHA — investigate why.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_5 — INSURER DISPATCH PERFORMANCE
-- Answers  : Which insurers have the worst claim submission rates?
-- UI       : Table sorted ascending by dispatch_rate_pct (worst first).
-- Returns  : 1 row per insurer with undispatched_kes and dispatch_rate_pct.
-- Normal   : Most insurers 50–85% dispatch rate all-time.
-- Alarming : Any insurer at 0% with >KES 1M outstanding = process failure.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_6 — ARPU TREND
-- Answers  : How has average revenue per patient changed over time?
-- UI       : Dual line chart — arpu_invoiced vs arpu_collected by month.
-- Returns  : 1 row per month with both ARPU values and rolling 3-month avg.
--   arpu_invoiced  = total_invoiced ÷ unique_patients (billed per patient)
--   arpu_collected = total_collected ÷ unique_patients (received per patient)
-- Normal   : arpu_invoiced KES 5,000–15,000. arpu_collected lower due to
--            payment data gaps.
-- Alarming : arpu_invoiced declining = more low-complexity visits or tariff
--            erosion. arpu_collected below KES 500 = near-zero collection.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_7 — PATIENT PARETO (top 100)
-- Answers  : Who are our highest-value patients?
-- UI       : Ranked table + Pareto curve — top 100 patients by collected KES.
-- Returns  : 100 rows with total_collected, active_months, cumulative_pct,
--            days_since_last_payment.
-- Normal   : Top 100 patients represent 20–40% of total collected.
-- Alarming : Single patient >5% of total collected = undue concentration.
-- Note     : Payment-record patients only — invoice-only patients excluded.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_8 — PATIENT PARETO CURVE BREAKPOINTS
-- Answers  : What % of our patient base generates 50/70/80/90% of revenue?
-- UI       : Insight text — "Top X% of patients = 80% of revenue."
-- Returns  : 4 rows, one per threshold (50, 70, 80, 90) with patients_needed
--            and pct_of_patients.
-- Example  : threshold=80 → patients_needed=320, pct_of_patients=6.1%
--            → "Top 6% of patients generate 80% of collected revenue."
-- Normal   : Top 15–25% of patients = 80% of revenue.
-- Alarming : Top 5% = 80% of revenue = extreme concentration, high churn risk.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_9 — PATIENT CLUSTERING
-- Answers  : How can we segment patients by value and recency?
-- UI       : Scatter or cluster chart — 1 point per patient, coloured by
--            segment.
-- Returns  : 1 row per patient with segment label.
--   Champion   : days_since_last ≤90  AND total_collected ≥10,000
--   Loyal      : days_since_last ≤180 AND total_collected ≥5,000
--   At Risk    : days_since_last 91–270
--   Lost       : days_since_last >270
--   New/Low    : all others
-- Normal   : Most patients will be At Risk or Lost (many one-time visitors).
-- Alarming : Champions declining month-on-month = best patients not returning.
-- Note     : KES thresholds (10,000 / 5,000) are configurable — validate
--            against clinical and financial context before publishing.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q3_10 — PATIENT SEGMENT SUMMARY
-- Answers  : How much revenue does each patient segment represent?
-- UI       : Summary tile row — count and revenue share per segment.
-- Returns  : 1 row per segment with patient_count, total_collected,
--            avg_collected, pct_of_total_revenue.
-- Normal   : Lost segment largest by count; Champions largest by revenue share.
-- Alarming : Champions <5% of count AND <15% of revenue = loyalty problem.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 4 — COLLECTIONS & CHANNELS
-- Purpose : What cash came in, how, and how fast. Collection rate trends,
--           channel mix shift, cash disappearance, DSO analysis.
-- Audience: Finance team, operations
-- Sources : rpt_rev_collections_monthly, rpt_rev_monthly_summary,
--           rpt_rev_ar_snapshot
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q4_1 — COLLECTION RATE TREND
-- Answers  : How much of what was invoiced has been collected each month?
-- UI       : Line chart with rolling 3-month average.
--            Recent months (within 60 days of data end) flagged as incomplete.
-- Returns  : 1 row per month with collection_rate_pct and incomplete flag.
-- Normal   : 6–14% given known payment data gaps.
-- Alarming : Below 6% for months older than 60 days (flag=FALSE) = genuine
--            collection failure, not a data completeness issue.
-- Note     : Same-month join — collection for month M may still be in-flight.
--            Do not compare recent months to older months without flagging this.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_2 — PAYMENT CHANNEL MIX TREND (absolute KES)
-- Answers  : How much did each payment channel collect each month in KES?
-- UI       : Stacked area chart — M-Pesa, Card, PesaPal, Cash, Cheque,
--            Patient Account.
-- Returns  : 1 row per month with each channel column in absolute KES.
-- Normal   : M-Pesa dominant. Cash near-zero from January 2025.
-- Alarming : PesaPal declining after a growth period = gateway issue.
-- Note     : Channel columns may sum to more than total_collected in some months
--            due to partial channel_sum population. Use Q4_3 for proportions.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_3 — CHANNEL MIX 100% STACKED
-- Answers  : What share of collections came from each channel each month?
-- UI       : 100% stacked bar chart — channel share by month.
-- Returns  : 1 row per month × channel in long format (6 channel rows per month)
--            with amount and pct.
-- Normal   : M-Pesa 55–70%; Cash near-zero post-January 2025; PesaPal growing.
-- Alarming : Cash reappearing above 5% after January 2025 = system change or
--            workaround in use. Unexplained PesaPal spike.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_4 — CASH DISAPPEARANCE POINT
-- Answers  : When did KSH effectively stop taking cash payments?
-- UI       : Line chart with threshold flag annotation.
-- Returns  : 1 row per month with cash_pct and cash_below_1pct flag.
-- Normal   : cash_pct < 1% from January 2025 — confirmed structural shift.
-- Alarming : Cash reappearing above 5% in months after January 2025.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_5 — WAIVER AND DISCOUNT ANALYSIS
-- Answers  : Are waivers or discounts being applied to payments?
-- UI       : Bar chart — total_waived and total_discounted by month.
-- Returns  : 1 row per month including zero-waiver months.
-- Normal   : All zeros currently — waiver/discount fields not populated in
--            source system. This is a data finding, not a query error.
-- Action   : If waivers/discounts exist in the business, check whether they
--            are recorded in stg_invoices.credit_amount instead (8.6% of
--            invoices have credit notes — that may be the real signal).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_6 — DSO — CASH SIDE
-- Answers  : How quickly do cash patients complete payment after billing?
-- UI       : Line chart — dso_days and dso_rolling_3m by month.
-- Returns  : 1 row per month.
--   dso_days = (est_cash_ar ÷ total_invoiced) × days_in_month
-- Normal   : 0–30 days. Cash should settle at point of service.
-- Alarming : Above 60 days = cash patients not completing payment promptly.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_7 — DSO — INSURER SIDE
-- Answers  : For each insurer, how long is the billing team taking to send
--            claims, and how long are insurers taking to pay after receiving?
-- UI       : Table — one row per insurer with both clock values.
-- Returns  : 1 row per insurer × ar_state with avg_days_outstanding and
--            avg_days_to_dispatch.
--   Undispatched rows   → delay_owner = "Billing team delay"
--   Dispatched rows     → delay_owner = "Insurer delay"
-- Normal   : Billing team 15–25 days to dispatch. Insurer 30–90 days to pay.
-- Alarming : Billing team >30 days = backlog. Insurer >365 days since dispatch
--            = likely unrecoverable without formal escalation.
-- Note     : Median days since dispatch currently 400–700 days for most
--            insurers — this is an active crisis, not a data artefact.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q4_8 — COLLECTION RATE BY PAYER TYPE
-- Answers  : Is collection rate different for cash vs insurer patients?
-- UI       : KPI tiles showing overall rate with payer context.
-- Returns  : 1 row per month with invoiced split and overall collection rate.
-- Note     : stg_payments has no payer flag — a true cash vs insurer split
--            of collections is not possible from current data. Overall rate only.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 5 — ACCOUNTS RECEIVABLE
-- Purpose : What is owed to KSH, how old is it, and who is responsible.
--           Uses the two-clock model: Undispatched = billing team delay;
--           Dispatched Awaiting Payment = insurer delay.
-- Audience: Billing team, finance
-- Sources : rpt_rev_ar_snapshot, rpt_rev_ar_aging, rpt_rev_payer_monthly
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q5_1 — AR HEADLINE KPIs
-- Answers  : What is the total open AR position right now?
-- UI       : Top KPI tile row — 4 tiles.
-- Returns  : 1 row with total_ar_kes, undispatched_ar_kes,
--            dispatched_unpaid_ar_kes, unknown_insurer_ar_kes.
-- Normal   : Undispatched <40% of total AR.
-- Alarming : Undispatched >60% (currently 61%) = billing team not sending
--            claims. This is an active operational failure.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_2 — AR BY INSURER AND STATE
-- Answers  : For each insurer, how much is undispatched vs dispatched-unpaid?
-- UI       : Full AR table — one row per insurer × AR state.
-- Returns  : N rows with insurer, state, open_invoices, outstanding_kes,
--            avg_days_outstanding, avg_days_to_dispatch.
-- Normal   : Most insurers have both undispatched and dispatched balances.
-- Alarming : Insurer with 100% undispatched and >KES 1M = blocked relationship
--            or systematic process failure for that insurer.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_3 — AR AGING HEATMAP
-- Answers  : How old is each insurer's AR?
-- UI       : Heatmap table — insurer rows × aging bucket columns
--            (0–30 / 31–60 / 61–90 / 90+), coloured by outstanding KES.
-- Returns  : 1 row per insurer × ar_state × aging_bucket.
--            Use bucket_sort column (1–4) for correct ordering.
-- Normal   : Most open AR is in 90+ bucket — normal for insurer billing cycles.
-- Alarming : 90+ undispatched bucket growing month-on-month = claims created
--            but never submitted.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_4 — AGING BUCKET SUMMARY
-- Answers  : Across all insurers, how much AR sits in each age bucket?
-- UI       : Summary bar chart — 4 bars (one per bucket) with KES amounts.
-- Returns  : 4–8 rows (one per bucket × ar_state combination).
-- Normal   : 90+ bucket will always dominate in insurer AR.
-- Alarming : 90+ undispatched >70% of total AR = systemic dispatch failure.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_5 — TOP 10 WORST UNDISPATCHED AR
-- Answers  : Which insurers have the most aged undispatched claims?
-- UI       : Priority action table — ranked by outstanding_90plus_kes.
-- Returns  : 10 rows of insurers with 90+ day undispatched AR.
-- Normal   : SHA and AAR Insurance are expected at the top given data.
-- Alarming : Any insurer >KES 5M in 90+ undispatched with no dispatch activity
--            in 6+ months = escalate immediately.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_6 — TWO-CLOCK ACCOUNTABILITY SPLIT
-- Answers  : For each insurer, is the delay ours or theirs?
-- UI       : Accountability table — billing team days vs insurer days per row.
-- Returns  : 1 row per insurer with:
--   median_days_to_dispatch   = billing team clock (invoice → dispatch)
--   median_days_since_dispatch = insurer clock (dispatch → today)
-- Normal   : Billing team 15–25 days. Insurer 30–90 days.
-- Alarming : Billing team >30 days = backlog. Insurer >365 days = near
--            unrecoverable. Currently 400–680 days for most insurers.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_7 — DISPATCH RATE TREND
-- Answers  : Is the dispatch rate improving, stable, or declining?
-- UI       : Line chart — dispatch_rate_pct by month.
-- Returns  : 1 row per month with dispatch_rate_pct and undispatched_kes.
-- Normal   : 50–85% in active billing months.
-- Alarming : 0% from September 2025 onward — confirmed operational failure.
--            This is not a data gap. Claims are not being submitted.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_8 — NULL COMPANY_ID BLIND SPOT DETAIL
-- Answers  : When did the unknown insurer AR problem start and is it growing?
-- UI       : Line chart — blind_spot_kes by month.
-- Returns  : Rows from June 2025 onward only (problem did not exist before).
-- Normal   : Zero rows before June 2025 = correct.
-- Alarming : Growing month-on-month after June 2025 = source system issue
--            that created the NULL company_id has not been resolved.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q5_9 — AR CONCENTRATION RISK
-- Answers  : How many insurers account for 80% of total open AR?
-- UI       : Pareto curve + insight text.
-- Returns  : 1 row per insurer with pct_of_ar and cumulative_pct.
-- Normal   : Top 5–8 insurers = 80% of open AR.
-- Alarming : Top 2–3 insurers = 80% of AR = extreme concentration. Any single
--            insurer >30% of AR = single-payer dependency risk.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 6 — REVENUE LEAKAGE
-- Purpose : Money earned clinically but not captured financially.
--           Six leakage vectors: pharmacy, consultations, AR undispatched,
--           unknown insurer AR, credit notes, and theatre unbilled.
-- Audience: Operations, clinical leads, billing team
-- Sources : rpt_rev_leakage_summary, rpt_rev_prescription_leakage,
--           rpt_rev_theatre_funnel, rpt_rev_top_items
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q6_1 — LEAKAGE RADAR SUMMARY
-- Answers  : What are the 6 leakage vectors and their KES exposures?
-- UI       : Ranked horizontal bar + Pareto donut.
-- Returns  : 5–6 rows ordered by leakage_kes DESC.
--            Unbilled Consultations row has NULL leakage_kes.
-- Normal   : Pharmacy Dispensed Unpaid = largest flow vector.
-- Alarming : Any vector growing >20% month-on-month.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_2 — TOTAL LEAKAGE KPI
-- Answers  : What is the total recoverable leakage exposure as a single number?
-- UI       : Headline KPI tile at top of leakage tab.
-- Returns  : 1 row with total_vectors, vectors_with_kes_value,
--            total_leakage_kes, data_through_date.
-- IMPORTANT: The KES 223M total is dominated by AR balance vectors (undispatched
--            AR KES 180M + unknown insurer KES 22M). These are open balances,
--            not monthly flow. Do not compare this figure month-to-month without
--            separating balance vectors from flow vectors (pharmacy, theatre).
-- data_through_date: pulled from MAX(invoice_date) in stg_invoices (~Apr 2026).
--                    More accurate than CURRENT_DATE for stakeholder reports.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_3 — PHARMACY LEAKAGE TREND
-- Answers  : Is pharmacy revenue leakage getting better or worse over time?
-- UI       : Line chart with outlier toggle.
-- Returns  : 1 row per month with leakage_kes_incl_outlier,
--            leakage_kes_excl_outlier, leakage_rate_pct, contains_outlier flag.
-- ALWAYS use leakage_kes_excl_outlier for trend analysis.
-- The March 2025 Nutriflex entry (KES 21M, 2 events) is a data entry error —
-- price × quantity ≥ 1,000,000 filter excludes it.
-- Normal   : 20–30% leakage rate in normal months.
-- Alarming : Rate above 35% sustained; rate rising 3+ months consecutively.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_4 — TOP 30 DRUGS BY LEAKAGE VALUE
-- Answers  : Which drugs account for the most pharmacy leakage by KES?
-- UI       : Ranked table — top 30 drugs.
-- Returns  : 30 rows with leakage_kes (excl outlier), leakage_events,
--            leakage_rate_pct.
-- Normal   : Injectables and antibiotics dominate (high unit price × volume).
-- Alarming : Single drug >30% of total pharmacy leakage = supply chain or
--            dispensing workflow issue requiring targeted fix.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_5 — DOCTOR LEAKAGE ACCOUNTABILITY
-- Answers  : Which doctors have the highest rate of unfilled prescriptions?
-- UI       : Table — top 20 doctors by unfilled KES.
-- Returns  : Up to 20 rows with prescriptions_written, unfilled_count,
--            unfilled_kes, unfilled_rate_pct. Min 10 prescriptions threshold.
-- Normal   : Most doctors 20–35% unfilled rate.
-- Alarming : Doctor above 50% unfilled with >100 prescriptions = prescribing
--            pattern or workflow problem requiring clinical discussion.
-- IMPORTANT: Doctor names not normalised — Dr. CHRISTINE ATOLO and
--            Dr. Christine Atolo are the same person. Fix at source before
--            using this view for formal accountability reporting.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_6 — PRESCRIPTION FULFILLMENT STATUS BREAKDOWN
-- Answers  : Of all prescriptions, how many are dispensed, cancelled, or leaked?
-- UI       : Status donut — 4 segments.
-- Returns  : 1 summary row with dispensed, cancelled_not_leakage,
--            filled_then_cancelled, leakage_unfilled counts and overall rate.
-- Normal   : Dispensed ~68%, Leakage ~24%, Cancelled ~8%.
-- Alarming : Leakage above 30% overall; cancelled rising may signal stock issues.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_7 — THEATRE BOOKING FUNNEL
-- Answers  : How does the theatre booking pipeline convert from booked to billed?
-- UI       : Funnel chart per month — booked → scheduled → completed → billed.
-- Returns  : 1 row per booking_month × status × is_scheduled × has_operation ×
--            is_billed.
-- Columns  : completion_rate_pct, billing_capture_rate_pct,
--            completed_unbilled_kes.
-- Normal   : Completion rate 85–100% in established months.
-- Alarming : Completion rate <70% = procedures not being done. Billing capture
--            <50% = completed procedures not being invoiced.
-- Note     : IS_BILLED via stg_theatre.visit_id → stg_invoices.visit join.
--            Confirm visit_id coverage before trusting billing_capture_rate_pct.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_8 — THEATRE FUNNEL SUMMARY
-- Answers  : Overall, what % of theatre bookings are completed and billed?
-- UI       : KPI tiles at top of theatre section.
-- Returns  : 1 row with total_bookings, completed_bookings, billed_bookings,
--            completed_unbilled_kes, overall completion and billing capture %.
-- Normal   : Completion >85%; billing capture TBD pending visit_id confirmation.
-- Alarming : Billing capture <50% = large share of completed procedures not
--            invoiced — quantified lost revenue opportunity.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_9 — REJECTED THEATRE BOOKINGS
-- Answers  : What theatre revenue was lost to rejections or cancellations?
-- UI       : Table — rejected bookings with reason and lost KES.
-- Returns  : 1 row per rejection reason group with lost_revenue_kes.
-- Normal   : Most rejections are operational (wrong entry, double booking).
-- Alarming : Clinical cancellations (procedure cancelled, mother delivered)
--            signal planning or capacity problems upstream.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_10 — UNBILLED CONSULTATIONS SUMMARY
-- Answers  : How many doctor encounters have no invoice attached?
-- UI       : KPI tile — visit count with caveat label.
-- Returns  : 1 row from leakage_summary where vector = Unbilled Consultations.
-- IMPORTANT: leakage_kes is NULL — no consultation tariff exists in
--            EVALUATION_PROCEDURES. Show visit count only. Do NOT estimate
--            or fabricate a KES value using an assumed tariff.
-- Normal   : Unbilled rate below 25%.
-- Alarming : Currently 36% overall and rising — already alarming.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q6_11 — OUTLIER DISCLOSURE
-- Answers  : What is the March 2025 Nutriflex outlier that was excluded?
-- UI       : Callout banner in pharmacy leakage section.
-- Returns  : Rows where contains_outlier = TRUE, showing excluded KES.
-- Purpose  : Transparency. Every exclusion must be visible and explained.
--            The Nutriflex entry (2 events, KES 21M) is a data entry error —
--            unit price × quantity was entered incorrectly in the source system.
-- Note     : If multiple outlier events appear across different months, this
--            indicates a systemic data entry problem — escalate to data ops.
-- -----------------------------------------------------------------------------


-- =============================================================================
-- TAB 7 — DATA QUALITY
-- Purpose : What to trust, what to caveat, and what is known to be broken.
--           For the analytics team and hospital management.
--           Not for external presentation or Gates Foundation reporting.
-- Audience: Analytics team, data ops
-- Sources : rpt_rev_data_quality, rpt_rev_monthly_summary,
--           rpt_rev_payer_monthly, rpt_rev_service_line_monthly
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q7_1 — ALL DATA QUALITY FLAGS
-- Answers  : What are all known data issues and their current values?
-- UI       : Full DQ table — metric, value, unit.
-- Returns  : 11 rows covering all flags computed in rpt_rev_data_quality.
-- Normal   : All metric values stable from last nightly refresh.
-- Alarming : Any metric value changed significantly since last run = pipeline
--            change or new source data issue.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_2 — OCTOBER 2025 EXCLUSION IMPACT
-- Answers  : How much revenue and how many invoices are excluded due to the
--            October 2025 anomaly?
-- UI       : Callout banner at top of DQ tab.
-- Returns  : 2 rows — invoice count and KES excluded.
-- Expected : 783 invoices, KES 10.3M excluded.
-- Alarming : These numbers changing = new data added or removed for that month.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_3 — NULL COMPANY_ID BLIND SPOT OVER TIME
-- Answers  : When did the unknown insurer AR problem start and is it growing?
-- UI       : Line chart — blind_spot_kes by month.
-- Returns  : Rows from June 2025 onward.
-- Normal   : Zero rows before June 2025.
-- Alarming : Growing month-on-month = root cause (system change in Jun 2025)
--            not yet resolved in the source system.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_4 — ZERO DISPATCH MONTHS DETAIL
-- Answers  : Which months had absolutely no insurer claim submissions?
-- UI       : Timeline bar — months with 0% dispatch shown in red.
-- Returns  : Months where SUM(dispatched_count) = 0 for insurer invoices.
-- Expected : September 2025 onward showing 0%.
-- IMPORTANT: This is a confirmed operational failure — not a data gap.
--            Do not impute, smooth, or exclude these months from trend charts.
--            Present them exactly as they are.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_5 — PAYMENT RECONCILIATION GAP TREND
-- Answers  : How large is the gap between what was declared as collected vs
--            what channel-level data shows?
-- UI       : Grouped bar — channel_sum vs total_invoiced by month.
-- Returns  : 1 row per month from rpt_rev_collections_monthly.
-- Expected : KES 64M gap across all time — known payment data incompleteness.
-- Normal   : Gap stable or narrowing as payment sync improves.
-- Alarming : Gap growing month-on-month = payment sync getting worse.
-- Note     : channel_sum is the reliable floor. total_collected from source
--            includes amounts not reflected in channel columns.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_6 — UNCLASSIFIED BILLING ITEMS BY MONTH
-- Answers  : What share of billing revenue has no service line classification?
-- UI       : Bar chart — unclassified_pct by month.
-- Returns  : 1 row per month with unclassified_revenue, total_revenue,
--            unclassified_pct, unclassified_rows.
-- Normal   : Below 10% in most months.
-- Alarming : Above 15% = classification gap in stg_billing_items. Primarily
--            affects PAYMENT_DETAIL stream rows (cash billing stream).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Q7_7 — DATA TRUST SUMMARY
-- Answers  : What should the analytics team caveat when presenting each metric?
-- UI       : Severity-sorted table — HIGH / MEDIUM / LOW with description.
-- Returns  : 10 hardcoded rows — static reference, not computed from data.
-- Severity guide:
--   HIGH   : Cannot be presented uncaveated. Add inline warning to dashboard.
--   MEDIUM : Known limitation — use clean version where one exists.
--   LOW    : Minor gap. Document and monitor. No dashboard change needed.
-- Note     : Update this query manually when new data issues are discovered
--            or existing issues are resolved in the source system.
-- -----------------------------------------------------------------------------