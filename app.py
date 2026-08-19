"""
KSH Revenue Intelligence — standalone Streamlit app.

Live revenue-cycle intelligence for Kisumu Specialist Hospital, reading from
HOSPITALS.REPORTING.rpt_rev_* (+ HOSPITALS.STAGING for data-anchored AR aging).

Run:  streamlit run app.py
Needs a .env (see .env.example) and the RSA key file it points to.
"""

import os
import sys
from pathlib import Path

import pandas as pd
import streamlit as st

st.set_page_config(page_title="KSH Revenue Intelligence", layout="wide",
                   initial_sidebar_state="expanded")

# Make the package importable as top-level `utils` / `queries` / `views`,
# matching how the platform loader mounts dashboards.
PKG = Path(__file__).resolve().parent / "ksh_revenue"
if str(PKG) not in sys.path:
    sys.path.insert(0, str(PKG))

from streamlit_option_menu import option_menu
import views
from queries import revenue as R, receivables as AR, leakage as L, analytics as A

views.setup()


# ── Load everything once (cached 1h) ──────────────────────────────────────────

@st.cache_data(ttl=3600, show_spinner=False)
def load_all(_v=5):
    dm = A.prepare_monthly(R.get_monthly_summary())
    snap = AR.get_ar_snapshot()
    leak = L.get_leakage_summary()
    exp = A.exposure_bridge(snap, leak)
    conc = R.get_insurer_concentration()
    theatre = L.get_theatre_summary()
    pharm_fulfil = L.get_pharmacy_fulfillment()
    unk = AR.get_unknown_insurer_trend()
    cutoff = AR.get_data_cutoff()
    aging = AR.get_undispatched_aging()
    return dict(
        dm=dm, snap=snap, leak=leak, exp=exp, conc=conc, theatre=theatre,
        pharm_fulfil=pharm_fulfil, unk=unk, cutoff=cutoff, aging=aging,
        signals=A.build_signals(dm, exp, unk, conc),
        actions=A.action_center(exp, snap, theatre, pharm_fulfil, conc),
        svc=R.get_service_line_monthly(), dow=R.get_timing_dow(), top_items=R.get_top_items(),
        dispatch=AR.get_dispatch_trend(), collections=AR.get_collections_monthly(),
        pharm_trend=L.get_pharmacy_trend(), top_drugs=L.get_top_drugs(),
        doctors=L.get_doctor_leakage(), outlier=L.get_pharmacy_outlier(),
        theatre_rej=L.get_theatre_rejections(), dq=L.get_data_quality(),
    )


with st.spinner("Loading revenue intelligence…"):
    D = load_all()

from types import SimpleNamespace

dm = D["dm"]
cur, prior = A.latest_complete(dm)
exp = D["exp"]
cutoff = D["cutoff"]
lag = A.data_lag_days(D["snap"], cutoff)
aging_dist = A.aging_distribution(D["aging"], exp.undispatched)
ninety_plus = float(aging_dist.loc[aging_dist["AGING_BUCKET"] == "90+ days", "KES"].sum())

# KES-weighted insurer sitting time on dispatched claims, re-anchored to cutoff
_snap = D["snap"].copy()
_snap["OUTSTANDING_KES"] = pd.to_numeric(_snap["OUTSTANDING_KES"], errors="coerce").fillna(0)
_snap["AVG_DAYS_OUTSTANDING"] = pd.to_numeric(_snap["AVG_DAYS_OUTSTANDING"], errors="coerce")
_disp = _snap[_snap["AR_STATE"].str.contains("Dispatched", na=False)].dropna(subset=["AVG_DAYS_OUTSTANDING"])
if _disp["OUTSTANDING_KES"].sum() > 0:
    _w = (_disp["AVG_DAYS_OUTSTANDING"] * _disp["OUTSTANDING_KES"]).sum() / _disp["OUTSTANDING_KES"].sum()
    dispatched_sitting_days = max(0.0, _w - lag)
else:
    dispatched_sitting_days = 0.0

ctx = SimpleNamespace(D=D, dm=dm, cur=cur, prior=prior, exp=exp, cutoff=cutoff, lag=lag,
                      aging_dist=aging_dist, ninety_plus=ninety_plus,
                      dispatched_sitting_days=dispatched_sitting_days,
                      signals=D["signals"], actions=D["actions"])


# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    logo = PKG / "assets" / "ksh_logo.png"
    if logo.exists():
        st.image(str(logo), use_container_width=True)
    st.markdown(
        f"<div style='font-size:13px;font-weight:700;color:#0F6E56'>"
        f"<span style='color:#0F6E56'>●</span> Kisumu Specialist Hospital</div>"
        f"<div style='font-size:11px;color:#9CA3AF'>Revenue cycle · data through {A.mon_label(cutoff)}</div>"
        "<hr style='margin:10px 0 6px;border:none;border-top:1px solid #E5E7EB'>",
        unsafe_allow_html=True)

    page = option_menu(
        menu_title=None,
        options=["Executive Brief", "Revenue", "Receivables & Cash", "Revenue Leakage", "Action Center"],
        icons=["speedometer2", "graph-up-arrow", "hourglass-split", "droplet-half", "lightning-charge"],
        default_index=0,
        styles={
            "container": {"padding": "0", "background-color": "transparent"},
            "icon": {"color": "#0F6E56", "font-size": "13px"},
            "nav-link": {"font-size": "13px", "font-weight": "500", "color": "#374151",
                         "padding": "8px 12px", "border-radius": "6px"},
            "nav-link-selected": {"background-color": "#F0FAF6", "color": "#0F6E56", "font-weight": "700"},
        })

    if A.has_inflight_month(dm) is not None:
        st.markdown(
            f"<div style='font-size:11px;color:#B45309;background:#FFFBEB;border:1px solid #FDE68A;"
            f"border-radius:6px;padding:7px 9px;margin-top:12px;line-height:1.4'>"
            f"⚠ {A.mon_label(A.has_inflight_month(dm))} is a partial month (last in the dataset) — headline figures "
            f"use the last complete month, {A.mon_label(cur['REV_MONTH'])}.</div>", unsafe_allow_html=True)

    views.data_notes_expander(ctx)

    if st.button("↺  Refresh data", use_container_width=True, type="secondary"):
        st.cache_data.clear()
        st.rerun()
    st.markdown("<div style='font-size:10px;color:#9CA3AF;margin-top:10px'>Afyanalytics · Revenue Intelligence</div>",
                unsafe_allow_html=True)

# deep-link / test override
_override = st.query_params.get("view")
if _override in views.VIEWS:
    page = _override

views.VIEWS[page](ctx)
