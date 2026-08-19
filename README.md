# KSH Revenue Intelligence

Live revenue-cycle intelligence for **Kisumu Specialist Hospital**, built on the
`HOSPITALS.REPORTING.rpt_rev_*` reporting layer (with `HOSPITALS.STAGING` used to
age receivables against the data cutoff). A Streamlit app that reads directly
from Snowflake via key-pair auth.

It is a decision product, not a report: five views move from **financial state →
cause → accountability → action**.

| View | Answers |
|------|---------|
| **Executive Brief** | How are we doing, how big is the exposure, what's recoverable, what's urgent, whose fault? |
| **Revenue** | Is revenue growing, and is it volume or case-value driven? |
| **Receivables & Cash** | Where is money stuck, how old is it, and is the delay ours or the insurer's? |
| **Revenue Leakage** | What clinical value isn't being captured (pharmacy, theatre, credit notes, consultations)? |
| **Action Center** | What should we act on first? |

## The headline

Billing is healthy (~KES 22–25M/month), but **~KES 295M of insurer receivables
is stuck and ~61% has never been dispatched** to insurers — claim dispatch
collapsed to **0% from September 2025**. The problem is largely internal and
recoverable. See the Executive Brief.

## Run locally

**Prerequisites:** Python 3.10+ and a Snowflake account with key-pair (RSA) auth
and read access to `HOSPITALS.REPORTING` + `HOSPITALS.STAGING`. You need your own
RSA **private key** file (`.p8`) and the matching public key registered on your
Snowflake user.

**1 — Clone and create a virtual environment**

```bash
git clone <this-repo-url>
cd KSH_REVENUE_ANALYTICS
python -m venv .venv
```

Activate it:
- **Windows (PowerShell):** `.venv\Scripts\Activate.ps1`  *(if blocked, run once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`)*
- **Windows (cmd):** `.venv\Scripts\activate.bat`
- **macOS / Linux:** `source .venv/bin/activate`

**2 — Install dependencies**

```bash
pip install -r requirements.txt
```

**3 — Configure credentials** (never committed — both are git-ignored)

```bash
cp .env.example .env            # Windows: copy .env.example .env
```

Edit `.env` with your account, user, warehouse, and the path to your key. Put the
key file in the repo root as `rsa_key.p8` (or point `SNOWFLAKE_PRIVATE_KEY_PATH`
at an absolute path).

**4 — Run**

```bash
streamlit run app.py
```

Open the URL Streamlit prints (usually `http://localhost:8501`). Append
`?view=Revenue` / `?view=Receivables & Cash` / etc. to deep-link a page.
Use **↺ Refresh data** in the sidebar to clear the 1-hour query cache.

> **Troubleshooting.** `&&` is not a statement separator in Windows PowerShell —
> run commands on separate lines or join with `;`. If the app renders dark, the
> pinned light theme in `.streamlit/config.toml` isn't being picked up — make
> sure you launch from the repo root.

## Documentation

- **[docs/ANALYTICS.md](docs/ANALYTICS.md)** — the full analysis: what every page
  shows, how each number is derived, the data sources, the methodology
  (exposure reconciliation, AR re-aging, signals, prioritisation), and every
  known data caveat. **Read this before presenting or extending the dashboard.**

## Configuration

Credentials come from `.env` (see `.env.example`). Both `.env` and the key file
are git-ignored — **never commit secrets**. Query results are cached for 1 hour;
use **↺ Refresh data** in the sidebar to clear the cache.

## Layout

```
app.py                     # entry: page config, data load, sidebar nav
ksh_revenue/
  views.py                 # the five views
  queries/                 # SQL → DataFrame (revenue, receivables, leakage) + analytics (derived logic)
  utils/                   # snowflake_conn, charts, components, formatting
  assets/
reporting_sql/             # B's rpt_rev_* reference queries (documentation)
.streamlit/config.toml     # pinned light theme
```

## Analytical notes (what to trust)

- **Latest month is partial** — headline KPIs anchor to the last *complete* month; the final month is shown flagged.
- **AR aging is re-anchored to the data cutoff**, not today — the reporting snapshot ages to `CURRENT_DATE`, which (with a data lag of several months) collapses everything into "90+". We re-age at invoice grain.
- **Exposure is counted once** — AR stock is separated from operational flow leakage; the unknown-insurer balance is a subset of AR, not an extra slice.
- **Collection rate is not shown as performance** — the payment feed is incomplete (~KES 64M gap); we show channel mix only.
- **Theatre billing-capture is contested** and the pharmacy Mar-2025 outlier is excluded — both disclosed in-app.


