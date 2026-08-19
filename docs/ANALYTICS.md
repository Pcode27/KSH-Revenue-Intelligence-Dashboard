# KSH Revenue Intelligence — Analytics & Methodology

This document explains **what every page shows, how each number is derived, which
warehouse objects it reads, and what to be careful about.** It is written for
colleagues who will maintain, extend, or present the dashboard.

For local setup see the [README](../README.md). This document is about the
*analysis*.

---

## 1. The headline

Kisumu Specialist Hospital's **billing is healthy** (~KES 22–25M invoiced per
month, growing) but it is **not converting billings into cash**. The dominant
fact is receivables:

- **KES ~295M** of insurer receivables is open.
- **~61% (KES ~181M) has never been dispatched** to insurers — it is stuck on
  *our* side of the process, not the insurer's.
- **Claim dispatch collapsed to 0% from September 2025** and has stayed there.
- The problem is therefore **largely internal and recoverable** (~KES 201M
  through internal action), not slow-paying insurers.

Everything in the dashboard builds toward that conclusion and toward a ranked
list of what to do about it.

---

## 2. Data sources & lineage

### 2.1 Reporting layer — `HOSPITALS.REPORTING.rpt_rev_*`

Built by the analytics team ("B") as a nightly, full-replace reporting layer over
`HOSPITALS.STAGING.*`. The dashboard reads these directly (fully-qualified,
cached 1 hour). Grain per table:

| Table | Grain |
|---|---|
| `rpt_rev_monthly_summary` | one row per calendar month (master fact) |
| `rpt_rev_service_line_monthly` | service line × billing source × month |
| `rpt_rev_timing` | day-of-week × week-of-month (all-time) |
| `rpt_rev_top_items` | item × service line (all-time) |
| `rpt_rev_payer_monthly` | payer × month |
| `rpt_rev_patient_value` | one row per patient (payment-record patients only) |
| `rpt_rev_collections_monthly` | one row per month (payments side) |
| `rpt_rev_ar_snapshot` | insurer × AR state (live snapshot) |
| `rpt_rev_ar_aging` | insurer × AR state × aging bucket (live snapshot) |
| `rpt_rev_leakage_summary` | one row per leakage vector |
| `rpt_rev_prescription_leakage` | drug × doctor × month |
| `rpt_rev_theatre_funnel` | booking status × month |
| `rpt_rev_data_quality` | one row per DQ metric |

### 2.2 Staging — `HOSPITALS.STAGING.STG_INVOICES`

Used for **one purpose**: to re-age the undispatched AR against the data cutoff
(see §3.3). Relevant columns: `invoice_date`, `for_cash`, `company_id`,
`balance`, `invoice_amount`, `dispatch_id`, `include_in_reporting`.

### 2.3 Global rules encoded upstream (inherited from the reporting layer)

- **October 2025 is excluded** from all trend tables (confirmed anomaly:
  783 invoices / KES 10.3M).
- **`IS_OUTLIER` rows excluded** from billing aggregates (5 rows, KES 500M —
  data-entry errors).
- Revenue = `amount` / `invoice_amount`, never `price × quantity`.
- Insurer AR uses `for_cash = 0` only.
- `channel_sum` is the canonical collection figure (not the declared total).
- NULL `company_id` invoices are surfaced as `⚠ Unknown (NULL company_id)`,
  never dropped.

---

## 3. Cross-cutting methodology

These are the decisions that most affect what the numbers mean. They live in
`ksh_revenue/queries/analytics.py`.

### 3.1 Pre-go-live ramp & partial-month detection

- **Billing go-live is September 2024.** April–August 2024 are a pre-go-live
  ramp (April 2024 has 21 invoices and 0 patients) and are **dropped from all
  trends** (`GO_LIVE = 2024-09-01`).
- The **final month in the data is treated as partial/in-flight** when its
  invoice count is < 75% of the trailing-3-month median *or* it drops > 25%
  month-on-month — the signature of an extract that cut the last month short.
  April 2026 (855 invoices vs a ~1,260 norm; −39% MoM) triggers this.
- **Headline KPIs therefore use the last *complete* month** (`latest_complete()`),
  and the partial month is drawn as a hollow "in-flight" marker, never as a
  real decline.

### 3.2 Exposure reconciliation — stock vs flow, counted once

Financial exposure is split into two kinds that must not be added naively:

- **Stock (a balance):** open AR = **undispatched (KES ~181M) + dispatched-unpaid
  (KES ~114M) = ~295M.** The **unknown-insurer balance (~KES 22.6M) is a *subset*
  of that AR** (it spans both states), not an additional amount.
- **Flow (a rate of loss):** operational leakage = pharmacy (~16.4M) + theatre
  (~2.1M) + credit notes (~2.2M) = **~20.7M**.

**Total de-duplicated exposure = AR stock + flow ≈ KES 315M.**
**Recoverable by internal action = undispatched + flow ≈ KES 201M** (counted
once — the unknown subset is inside the undispatched book, not on top of it).

> A commonly-cited "KES 223M leakage" number elsewhere mixed the AR balance
> vectors with the flow vectors and double-counted the receivable. This
> dashboard keeps them separate. (`exposure_bridge()`.)

### 3.3 AR aging re-anchored to the data cutoff

**Problem.** `rpt_rev_ar_snapshot.snapshot_date` = `CURRENT_DATE`, but the newest
invoice is ~April 2026. When the dashboard is viewed months later, every
"days outstanding" is inflated by the gap and **100% of AR falls into the "90+"
bucket** — the aging becomes uninformative.

**Fix.** `get_undispatched_aging()` re-ages the undispatched book **at invoice
grain from `invoice_date` to the data cutoff** (`MAX(invoice_date)`), recovering
a real distribution. Day-count metrics (e.g. insurer sitting time) are corrected
by subtracting the data lag (`data_lag_days()`).

Result (undispatched, anchored to the cutoff):

| Bucket | Share | ≈ KES |
|---|---|---|
| 0–30 days | ~10% | ~18M |
| 31–60 days | ~11% | ~20M |
| 61–90 days | ~9% | ~16M |
| **90+ days** | **~70%** | **~127M** |

The staging re-age reconciles to the reporting undispatched balance within ~5%
(171.9M vs 180.6M, different open-balance definitions), so the dashboard shows
the buckets as **shares of the authoritative reporting total** — the age *shape*
is from staging, the *total* stays consistent with every other page.
(`aging_distribution()`.)

### 3.4 Signals — only what fires, on corrected logic

`build_signals()` returns alerts most-severe-first, and only when breached:

1. **Dispatch collapse** — latest complete month at 0% dispatch (CRITICAL).
2. **Undispatched AR above threshold** — undispatched > 55% of AR (CRITICAL).
3. **Unknown-insurer AR blind spot** — unattributable AR present (MEDIUM).
4. **Revenue below trend** — complete month > 10% below its 3-month average
   (MEDIUM; does not fire on the partial month).
5. **SHA payer concentration** — SHA share of insurer revenue vs a 35% guardrail
   (WATCH/MEDIUM). *This corrects an earlier version that compared **total
   insurer** share against 35% and so always fired.*

### 3.5 Action prioritisation — a transparent framework, not a black box

`action_center()` orders opportunities by **recoverable KES value**, then
attaches **urgency** (age), **concentration** (fewer payers = easier), and a
named **owner**. Balances are decomposed so the worklist sums without
double-counting: the undispatched book (KES ~181M) is split into the *attributed*
part (row 1) and the *unknown-insurer* part that needs a data fix first (row 3).

---

## 4. Page by page

### 4.1 Executive Brief
**Purpose:** the whole story in 30 seconds — state → problem → cause →
accountability, then the exposure and the 2–3 signals that matter.

| Element | Definition / derivation | Source |
|---|---|---|
| Diagnosis strip | Narrative summary of the four facts below | derived |
| Gross revenue (last complete month) + MoM | `total_invoiced`, MoM vs prior complete month | `monthly_summary` |
| Open insurer receivables | undispatched + dispatched | `ar_snapshot` |
| Recoverable by internal action | undispatched + flow leakage (counted once) | `ar_snapshot` + `leakage_summary` |
| Aged 90+ & undispatched | 90+ bucket of the re-anchored aging | `stg_invoices` |
| Revenue trend | monthly invoiced + 3-mo rolling avg, partial month flagged | `monthly_summary` |
| Payer mix | insurer vs cash share of invoiced | `monthly_summary` |
| Exposure split | two-clock stacked bar (undispatched vs dispatched) | `ar_snapshot` |
| Signals | see §3.4 | derived |

**Caveats:** revenue MoM uses complete months only; exposure is a live snapshot.

### 4.2 Revenue
**Purpose:** is revenue growing, and what drives it?

| Element | Definition | Source |
|---|---|---|
| KPIs | last-complete-month invoiced, invoice count, avg invoice value, peak month | `monthly_summary` |
| Billing trend | invoiced + 6-mo rolling avg | `monthly_summary` |
| Revenue drivers | change decomposed into **volume** = Δcount × prior avg-invoice, and **intensity** = Δavg-invoice × prior count | `monthly_summary` |
| Service-line share shift | current vs ~6-months-prior share, in pp | `service_line_monthly` |
| Revenue by day of week | avg daily invoiced per weekday | `timing` |
| Top revenue items | all-time revenue per item | `top_items` |

**Key finding (drivers):** month-to-month **swings are intensity-led**
(Σ\|intensity\| ≈ 36M vs Σ\|volume\| ≈ 16M), i.e. case mix / tariffs move revenue
more than patient counts. The **underlying base has grown on volume** (patient
count +41% since go-live vs case value +16%). Say both — they are not
contradictory.

**Caveats:** the week-of-month cut was dropped (near-flat, no decision value);
"Copay" is excluded from the share-shift chart as a non-clinical line.

### 4.3 Receivables & Cash
**Purpose:** where is money stuck, how old, and whose delay is it?

| Element | Definition | Source |
|---|---|---|
| KPIs | total AR, undispatched (% of AR), aged 90+ undispatched, insurer sitting time (re-anchored) | `ar_snapshot` + `stg_invoices` |
| Accountability by insurer | per-insurer undispatched vs dispatched (two-clock) | `ar_snapshot` |
| Dispatch rate trend | monthly dispatched ÷ insurer invoices | `payer_monthly` |
| Undispatched AR by age | re-anchored aging distribution (§3.3) | `stg_invoices` |
| Concentration | insurer invoiced Pareto (cumulative %) | `payer_monthly` |
| Receivables detail | per-insurer undispatched / dispatched / total | `ar_snapshot` |
| Channel mix over time | 100% stacked payment channels | `collections_monthly` |
| SHA concentration | SHA share of insurer invoiced | `payer_monthly` |

**The two-clock model** is the backbone: **Undispatched = our delay** (clock from
invoice creation — we haven't sent the claim); **Dispatched-awaiting-payment =
insurer delay** (clock from dispatch). It converts a vague "large AR" into a
clear accountability split — here, mostly ours.

**Caveats:**
- **We do not show a collection rate.** The payment feed is incomplete
  (~KES 64M gap between the declared total and channel sums) and most AR is not
  yet due, so a same-month collection rate would misrepresent performance. Only
  the channel *mix* and the cash→digital shift (cash < 1% from Jan 2025) are
  shown.
- Insurer sitting time is KES-weighted and re-anchored to the cutoff; there is
  no dispatch-date table, so dispatched-side aging is approximate.

### 4.4 Revenue Leakage
**Purpose:** clinical value earned but not captured — **flow vectors only**
(AR lives on the Receivables page; keeping them apart avoids double-counting).

| Element | Definition | Source |
|---|---|---|
| KPIs | flow total, pharmacy dispensed-unpaid (+ rate), theatre completed-unbilled, unbilled consultation count | `leakage_summary`, `prescription_leakage` |
| Pharmacy leakage trend | monthly unfilled value, outlier excluded | `prescription_leakage` |
| Fulfillment | dispensed / leakage / cancelled split | `prescription_leakage` |
| Top drugs / prescribers | leakage KES by drug and by doctor | `prescription_leakage` |
| Theatre funnel | booked → scheduled → completed → billed | `theatre_funnel` |

**Caveats:**
- **Unbilled consultations are a count only** — there is no consultation tariff
  in the source, so no KES is fabricated.
- **Theatre billing capture is uncertain** — the funnel and the leakage table
  disagree because the theatre-to-invoice link is incomplete; treat the figure
  as indicative.
- **Pharmacy Mar-2025 outlier** (KES 21M Nutriflex) is excluded from every
  pharmacy figure.
- **Doctor names are not normalised** (case variants) — prescriber rows are
  indicative until merged at source.

### 4.5 Action Center
**Purpose:** the payoff — what to act on first.

A ranked worklist (§3.5) with, per opportunity: exposure KES, volume, age,
concentration, owner, recoverability, and a concrete first action. Plus a
by-owner rollup and a sequenced 90-day play. The top 3 actions
(restart dispatch, fix unknown-insurer, escalate aged dispatched) unlock the
large majority of the recoverable total.

---

## 5. Known data issues (the register)

| Severity | Issue | Handling in the dashboard |
|---|---|---|
| HIGH | Dispatch 0% from Sep 2025 | Shown as-is (real failure), never imputed |
| HIGH | Collection rate unreliable (KES 64M feed gap) | No collection-rate KPI; channel mix only |
| HIGH | AR snapshot ages to today, not the data cutoff | Re-aged at invoice grain (§3.3) |
| MEDIUM | Unknown-insurer AR (KES ~22.6M, from ~Jun 2025) | Surfaced as its own row; needs a source-system fix |
| MEDIUM | Theatre billing capture (visit-to-invoice link) | Flagged as indicative |
| MEDIUM | Pharmacy Mar-2025 outlier (KES 21M) | Excluded, disclosed |
| MEDIUM | Doctor names not normalised | Flagged as indicative |
| LOW | Unclassified billing items (up to ~17% of revenue some months; 55.6M / 16,522 rows all-time) | Kept as an "Unclassified" service line |
| LOW | Patient-value table = payment-record patients only | Patient analytics treated as indicative |

---

## 6. Relationship to the reporting layer & what this dashboard adds

The reporting layer (rpt_rev_*) is the analytical foundation and is trusted for
totals. On top of it this dashboard:

- **separates stock from flow** and counts exposure once (§3.2);
- **re-ages AR to the data cutoff** instead of today (§3.3);
- **detects the partial final month** and anchors KPIs to the last complete
  month (§3.1);
- **corrects the SHA concentration signal** (§3.4);
- **reframes collections** as mix, not performance (§4.3);
- **adds a prioritised, owned Action Center** (§3.5).

Verified reconciliations (live): AR 294.6M; undispatched 180.6M (61%);
dispatched 114.1M; unknown 22.6M; flow leakage 20.7M; pharmacy leakage rate 24%;
patient revenue concentration top ~36% of patients → 80% of collected; SHA ~29%
of insurer revenue.

---

## 7. Extending the dashboard (developer notes)

- **Add a query:** put a cached `run_query(...)` function in the relevant
  `ksh_revenue/queries/*.py`; load it in `load_all()` (both `app.py` and the
  platform entry).
- **Add derived logic:** `queries/analytics.py`, kept out of the query layer so
  SQL stays thin.
- **Add a chart:** a builder in `utils/charts.py` returning a `go.Figure` in the
  house `_LAYOUT` style; render with
  `st.plotly_chart(fig, use_container_width=True, config={"displayModeBar": False})`.
- **Add to a page:** edit the relevant `view_*` in `ksh_revenue/views.py`. Both
  entries share this module, so changes appear in the standalone app and the
  platform loader.
- **On-page text is for stakeholders; methodology caveats belong in the sidebar
  "Data notes & caveats"** (`views.data_notes_expander`).
