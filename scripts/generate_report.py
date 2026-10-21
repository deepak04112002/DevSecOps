#!/usr/bin/env python3
"""
generate_report.py

Builds a security report from DefectDojo active findings and writes:
  artifacts/report/security-report.html   self-contained, opens in any browser
  artifacts/report/security-report.pdf    same content, rendered by WeasyPrint

Exit codes:
  0  HTML and PDF written
  1  could not fetch findings from DefectDojo (fatal)
  2  HTML written, PDF failed (Jenkins marks the stage UNSTABLE)

Environment:
  DEFECTDOJO_URL, DEFECTDOJO_API_TOKEN          required
  DEFECTDOJO_ENGAGEMENT_ID                      optional, used for the link
  DEFECTDOJO_ENGAGEMENT_NAME, DEFECTDOJO_PRODUCT_NAME
  JOB_NAME, BUILD_NUMBER, BUILD_URL, GIT_COMMIT
  PAGE_SIZE                                     default 100
  REPORT_MAX_ROWS_PER_SEVERITY                  default 300
"""
import html
import json
import math
import os
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

OUT_DIR = Path("artifacts/report")
HTML_PATH = OUT_DIR / "security-report.html"
PDF_PATH = OUT_DIR / "security-report.pdf"

PAGE_SIZE = int(os.environ.get("PAGE_SIZE", "100"))
MAX_ROWS_PER_SEVERITY = int(os.environ.get("REPORT_MAX_ROWS_PER_SEVERITY", "300"))

SEVERITIES = ["Critical", "High", "Medium", "Low", "Info"]
SEV_COLORS = {
    "Critical": "#b91c1c",
    "High": "#ea580c",
    "Medium": "#ca8a04",
    "Low": "#15803d",
    "Info": "#2563eb",
}
SEV_ALIASES = {
    "critical": "Critical",
    "high": "High",
    "medium": "Medium",
    "low": "Low",
    "info": "Info",
    "informational": "Info",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def esc(value) -> str:
    if value is None:
        return ""
    return html.escape(str(value), quote=True)


def truncate(text, limit: int) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def fmt_cvss(value) -> str:
    if value is None:
        return "–"
    return f"{value:.1f}"


def badge(sev: str) -> str:
    return f'<span class="badge" style="background:{SEV_COLORS[sev]}">{sev}</span>'


def log(msg: str) -> None:
    print(f"[report] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[report] WARNING: {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    print(f"[report] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------------------
# DefectDojo API
# ---------------------------------------------------------------------------
def api_get(path: str, params: dict) -> dict:
    base = os.environ["DEFECTDOJO_URL"].rstrip("/")
    token = os.environ["DEFECTDOJO_API_TOKEN"]
    url = f"{base}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Token {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_paginated(path: str, params: dict) -> list:
    items, offset = [], 0
    while True:
        page = api_get(path, {**params, "limit": PAGE_SIZE, "offset": offset})
        results = page.get("results", [])
        items.extend(results)
        offset += len(results)
        if not results or offset >= page.get("count", 0):
            return items


def normalize(raw: dict, test_titles: dict, base: str) -> dict:
    cves = []
    for v in raw.get("vulnerability_ids") or []:
        vid = (v.get("vulnerability_id") or v.get("name")) if isinstance(v, dict) else v
        if vid:
            cves.append(str(vid))

    cvss = raw.get("cvssv3_score")
    if cvss in (None, ""):
        cvss = raw.get("cvssv2_score")
    try:
        cvss = float(cvss) if cvss not in (None, "") else None
    except (TypeError, ValueError):
        cvss = None

    location = raw.get("file_path") or raw.get("component_name") or ""
    if location and raw.get("line"):
        location = f"{location}:{raw['line']}"

    component = " ".join(
        x for x in (raw.get("component_name") or "", raw.get("component_version") or "") if x
    )

    cwe = raw.get("cwe")
    return {
        "id": raw.get("id"),
        "url": f"{base}/finding/{raw.get('id')}",
        "severity": SEV_ALIASES.get(str(raw.get("severity") or "").strip().lower(), "Info"),
        "title": raw.get("title") or raw.get("component_name") or "Untitled finding",
        "scanner": test_titles.get(raw.get("test"), "Unknown"),
        "location": location,
        "component": component,
        "fix": raw.get("fix_version") or raw.get("mitigation") or "",
        "cvss": cvss,
        "cwe": f"CWE-{cwe}" if cwe not in (None, "", 0) else "",
        "cves": cves,
        "description": raw.get("description") or "",
    }


def risk_posture(counts: Counter, total: int):
    if total == 0:
        return "No active findings", SEV_COLORS["Low"]
    for sev in ("Critical", "High", "Medium"):
        if counts[sev]:
            return f"{sev} risk", SEV_COLORS[sev]
    return "Low risk", SEV_COLORS["Low"]


# ---------------------------------------------------------------------------
# SVG charts (inline, so they render in both the browser and WeasyPrint)
# ---------------------------------------------------------------------------
def svg(width: int, height: int, body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="DejaVu Sans, Helvetica, Arial, sans-serif">'
        f"{body}</svg>"
    )


def donut_chart(counts: Counter, total: int) -> str:
    size, r, sw = 200, 70, 28
    c = size / 2
    parts = []
    if total == 0:
        parts.append(f'<circle cx="{c}" cy="{c}" r="{r}" fill="none" stroke="#e2e8f0" stroke-width="{sw}"/>')
    else:
        start = -math.pi / 2
        for sev in SEVERITIES:
            n = counts[sev]
            if not n:
                continue
            frac = n / total
            color = SEV_COLORS[sev]
            if frac >= 1:
                parts.append(f'<circle cx="{c}" cy="{c}" r="{r}" fill="none" stroke="{color}" stroke-width="{sw}"/>')
                break
            end = start + frac * 2 * math.pi
            x1, y1 = c + r * math.cos(start), c + r * math.sin(start)
            x2, y2 = c + r * math.cos(end), c + r * math.sin(end)
            large = 1 if frac > 0.5 else 0
            parts.append(
                f'<path d="M{x1:.2f} {y1:.2f} A{r} {r} 0 {large} 1 {x2:.2f} {y2:.2f}" '
                f'fill="none" stroke="{color}" stroke-width="{sw}"/>'
            )
            start = end
    parts.append(
        f'<text x="{c}" y="{c + 4}" text-anchor="middle" font-size="30" '
        f'font-weight="bold" fill="#0f172a">{total}</text>'
    )
    parts.append(
        f'<text x="{c}" y="{c + 24}" text-anchor="middle" font-size="10" fill="#64748b">'
        f"active findings</text>"
    )
    return svg(size, size, "".join(parts))


def severity_bars(counts: Counter) -> str:
    label_w, bar_w, row_h = 70, 260, 32
    peak = max([counts[s] for s in SEVERITIES] + [1])
    body = []
    for i, sev in enumerate(SEVERITIES):
        y = i * row_h
        n = counts[sev]
        w = n / peak * bar_w
        body.append(f'<text x="0" y="{y + 19}" font-size="10" fill="#334155">{sev}</text>')
        body.append(
            f'<rect x="{label_w}" y="{y + 6}" width="{bar_w}" height="16" rx="3" fill="#f1f5f9"/>'
        )
        if n:
            body.append(
                f'<rect x="{label_w}" y="{y + 6}" width="{max(w, 2):.1f}" height="16" rx="3" '
                f'fill="{SEV_COLORS[sev]}"/>'
            )
        body.append(
            f'<text x="{label_w + bar_w + 8}" y="{y + 19}" font-size="10" font-weight="bold" '
            f'fill="#0f172a">{n}</text>'
        )
    return svg(label_w + bar_w + 40, row_h * len(SEVERITIES), "".join(body))


def scanner_bars(by_scanner: dict) -> str:
    rows = sorted(by_scanner.items(), key=lambda kv: -sum(kv[1].values()))[:10]
    if not rows:
        return ""
    label_w, bar_w, row_h = 170, 400, 30
    peak = max(sum(c.values()) for _, c in rows)
    body = []
    for i, (name, counts) in enumerate(rows):
        y = i * row_h
        body.append(
            f'<text x="0" y="{y + 19}" font-size="10" fill="#334155">{esc(truncate(name, 26))}</text>'
        )
        x = label_w
        for sev in SEVERITIES:
            n = counts[sev]
            if not n:
                continue
            w = n / peak * bar_w
            body.append(
                f'<rect x="{x:.1f}" y="{y + 6}" width="{w:.1f}" height="16" fill="{SEV_COLORS[sev]}"/>'
            )
            x += w
        total = sum(counts.values())
        body.append(
            f'<text x="{x + 6:.1f}" y="{y + 19}" font-size="10" font-weight="bold" '
            f'fill="#0f172a">{total}</text>'
        )
    return svg(label_w + bar_w + 50, row_h * len(rows), "".join(body))


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------
CSS = """
@page {
  size: A4;
  margin: 16mm 14mm 18mm 14mm;
  @bottom-left  { content: "Security Report"; font-size: 7.5pt; color: #64748b; }
  @bottom-right { content: "Page " counter(page) " of " counter(pages); font-size: 7.5pt; color: #64748b; }
}
@page land {
  size: A4 landscape;
  margin: 14mm 12mm 16mm 12mm;
  @bottom-left  { content: "Security Report"; font-size: 7.5pt; color: #64748b; }
  @bottom-right { content: "Page " counter(page) " of " counter(pages); font-size: 7.5pt; color: #64748b; }
}
body { font-family: "DejaVu Sans", "Helvetica Neue", Arial, sans-serif; font-size: 9pt; color: #0f172a; margin: 0; }
.landscape { page: land; }

.hero { background: #0f172a; color: #ffffff; padding: 22px 24px; }
.hero h1 { margin: 0; font-size: 22pt; }
.hero .sub { color: #94a3b8; font-size: 10pt; margin-top: 4px; }
.pill { display: inline-block; margin-top: 12px; padding: 4px 12px; border-radius: 12px;
        font-weight: bold; font-size: 9pt; color: #ffffff; }

table.kpis { width: 100%; border-collapse: separate; border-spacing: 6px; margin: 12px 0 2px -6px; }
table.kpis td { text-align: center; padding: 12px 4px; color: #ffffff; border-radius: 6px; }
.kpi-num { font-size: 24pt; font-weight: bold; line-height: 1; }
.kpi-lbl { font-size: 8pt; text-transform: uppercase; margin-top: 4px; }

h2 { font-size: 12.5pt; margin: 20px 0 8px; padding-bottom: 4px; border-bottom: 2px solid #0f172a; }
h3 { font-size: 10.5pt; margin: 16px 0 6px; }
.count { color: #64748b; font-weight: normal; font-size: 9pt; }
.note { color: #64748b; font-size: 8pt; margin: 2px 0 6px; }

table.meta { width: 100%; border-collapse: collapse; font-size: 8.5pt; margin-top: 10px; }
table.meta td { padding: 4px 6px; border-bottom: 1px solid #e2e8f0; }
table.meta td.k { width: 120px; color: #64748b; font-weight: bold; }

table.charts { width: 100%; border-collapse: collapse; margin-top: 4px; }
table.charts td { vertical-align: top; padding: 6px 4px; }
.legend { font-size: 8pt; color: #334155; margin-top: 6px; }
.legend span { display: block; margin: 3px 0; }
.legend i { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 6px; }

table.data { width: 100%; border-collapse: collapse; font-size: 8.5pt; }
table.data thead { display: table-header-group; }
table.data th { background: #0f172a; color: #ffffff; text-align: left; padding: 6px 7px; font-weight: bold; }
table.data td { padding: 5px 7px; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
table.data tr { page-break-inside: avoid; }
table.data tr:nth-child(even) td { background: #f8fafc; }
table.ft td { font-size: 7.8pt; }

.badge { display: inline-block; padding: 1px 7px; border-radius: 8px; color: #ffffff;
         font-size: 7.5pt; font-weight: bold; }
.ftitle { font-weight: bold; font-size: 8.5pt; }
.fdesc { color: #475569; font-size: 7.5pt; margin-top: 2px; }
.mono { font-family: "DejaVu Sans Mono", monospace; font-size: 7.5pt; overflow-wrap: break-word; }
.nowrap { white-space: nowrap; }
.num { text-align: right; }
a { color: #1e3a8a; text-decoration: none; }
.method { color: #475569; font-size: 8pt; margin-top: 16px; }

@media screen {
  body { background: #e2e8f0; }
  .sheet { max-width: 900px; margin: 24px auto; background: #ffffff; padding: 28px 32px; }
}
"""


def top_rows(findings: list) -> str:
    if not findings:
        return '<tr><td colspan="5">No active findings.</td></tr>'
    top = sorted(findings, key=lambda f: (SEVERITIES.index(f["severity"]), -(f["cvss"] or 0)))[:10]
    return "".join(
        "<tr>"
        f'<td class="nowrap"><a href="{esc(f["url"])}">#{esc(f["id"])}</a></td>'
        f"<td>{badge(f['severity'])}</td>"
        f'<td>{esc(truncate(f["title"], 90))}</td>'
        f'<td>{esc(f["scanner"])}</td>'
        f'<td class="num">{fmt_cvss(f["cvss"])}</td>'
        "</tr>"
        for f in top
    )


def scanner_rows(by_scanner: dict) -> str:
    if not by_scanner:
        return '<tr><td colspan="7">No active findings.</td></tr>'
    rows = []
    for name, c in sorted(by_scanner.items(), key=lambda kv: -sum(kv[1].values())):
        cells = "".join(f'<td class="num">{c[s] or "–"}</td>' for s in SEVERITIES)
        rows.append(
            f"<tr><td>{esc(name)}</td>{cells}"
            f'<td class="num"><b>{sum(c.values())}</b></td></tr>'
        )
    return "".join(rows)


def findings_section(findings: list) -> str:
    if not findings:
        return '<section class="landscape"><h2>Findings</h2><p>No active findings.</p></section>'

    parts = ['<section class="landscape"><h2>Findings by severity</h2>']
    for sev in SEVERITIES:
        items = sorted((f for f in findings if f["severity"] == sev), key=lambda f: -(f["cvss"] or 0))
        if not items:
            continue
        shown = items[:MAX_ROWS_PER_SEVERITY]
        parts.append(f'<h3>{badge(sev)} <span class="count">{len(items)} active</span></h3>')
        if len(items) > len(shown):
            parts.append(
                f'<p class="note">Showing {len(shown)} of {len(items)}. '
                f"The full list is in DefectDojo.</p>"
            )
        parts.append(
            '<table class="data ft"><thead><tr>'
            "<th>ID</th><th>Finding</th><th>Scanner</th><th>Location</th>"
            "<th>Component</th><th>Fix</th><th class=\"num\">CVSS</th>"
            "<th>CWE</th><th>CVE</th>"
            "</tr></thead><tbody>"
        )
        for f in shown:
            parts.append(
                "<tr>"
                f'<td class="nowrap"><a href="{esc(f["url"])}">#{esc(f["id"])}</a></td>'
                f'<td><div class="ftitle">{esc(truncate(f["title"], 140))}</div>'
                f'<div class="fdesc">{esc(truncate(f["description"], 260))}</div></td>'
                f'<td>{esc(f["scanner"])}</td>'
                f'<td class="mono">{esc(f["location"])}</td>'
                f'<td class="mono">{esc(f["component"])}</td>'
                f'<td class="mono">{esc(truncate(f["fix"], 80))}</td>'
                f'<td class="num">{fmt_cvss(f["cvss"])}</td>'
                f'<td class="nowrap">{esc(f["cwe"])}</td>'
                f'<td class="mono">{esc(", ".join(f["cves"]))}</td>'
                "</tr>"
            )
        parts.append("</tbody></table>")
    parts.append("</section>")
    return "".join(parts)


def build_html(ctx: dict) -> str:
    findings, counts, total = ctx["findings"], ctx["counts"], len(ctx["findings"])
    posture, posture_color = risk_posture(counts, total)

    kpis = "".join(
        f'<td style="background:{SEV_COLORS[s]}"><div class="kpi-num">{counts[s]}</div>'
        f'<div class="kpi-lbl">{s}</div></td>'
        for s in SEVERITIES
    )
    legend = "".join(
        f'<span><i style="background:{SEV_COLORS[s]}"></i>{s}: {counts[s]}</span>' for s in SEVERITIES
    )
    scanner_chart = scanner_bars(ctx["by_scanner"]) or "<p>No findings.</p>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Security Report - {esc(ctx["product"])} #{esc(ctx["build"])}</title>
<style>{CSS}</style>
</head>
<body>
<div class="sheet">

<div class="hero">
  <h1>Security Report</h1>
  <div class="sub">{esc(ctx["product"])} &middot; {esc(ctx["engagement"])}</div>
  <span class="pill" style="background:{posture_color}">{esc(posture)}</span>
</div>

<table class="meta">
  <tr><td class="k">Job</td><td>{esc(ctx["job"])}</td>
      <td class="k">Build</td><td>#{esc(ctx["build"])}</td></tr>
  <tr><td class="k">Git commit</td><td class="mono">{esc(ctx["commit"])}</td>
      <td class="k">Generated</td><td>{esc(ctx["generated"])}</td></tr>
  <tr><td class="k">Build URL</td><td colspan="3"><a href="{esc(ctx["build_url"])}">{esc(ctx["build_url"] or "Unavailable")}</a></td></tr>
  <tr><td class="k">DefectDojo</td><td colspan="3"><a href="{esc(ctx["engagement_url"])}">{esc(ctx["engagement_url"])}</a></td></tr>
</table>

<h2>Executive summary</h2>
<table class="kpis"><tr>{kpis}</tr></table>

<table class="charts"><tr>
  <td style="width:42%">
    {donut_chart(counts, total)}
    <div class="legend">{legend}</div>
  </td>
  <td style="width:58%">
    <div style="font-size:9pt;font-weight:bold;margin-bottom:6px;">Findings by severity</div>
    {severity_bars(counts)}
  </td>
</tr></table>

<h2>Findings by scanner</h2>
<table class="charts"><tr><td>{scanner_chart}</td></tr></table>
<table class="data" style="margin-top:10px">
  <thead><tr>
    <th>Scanner</th>
    <th class="num">Critical</th><th class="num">High</th><th class="num">Medium</th>
    <th class="num">Low</th><th class="num">Info</th><th class="num">Total</th>
  </tr></thead>
  <tbody>{scanner_rows(ctx["by_scanner"])}</tbody>
</table>

<h2>Top 10 risks</h2>
<table class="data">
  <thead><tr><th>ID</th><th>Severity</th><th>Title</th><th>Scanner</th><th class="num">CVSS</th></tr></thead>
  <tbody>{top_rows(findings)}</tbody>
</table>

<p class="method">
  Source: DefectDojo active findings for {esc(ctx["product"])}. This report reflects the state at
  build time. Findings are tracked in DefectDojo; scores come from each finding's CVSS data where available.
</p>

{findings_section(findings)}

</div>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# PDF
# ---------------------------------------------------------------------------
def write_pdf(html_doc: str) -> bool:
    try:
        from weasyprint import HTML  # imported here so a missing install doesn't stop the HTML
        HTML(string=html_doc).write_pdf(str(PDF_PATH))
        return True
    except Exception as exc:
        warn(f"PDF generation failed (weasyprint not installed or missing system libs?): {exc}")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    base = os.environ.get("DEFECTDOJO_URL", "").rstrip("/")
    if not base or not os.environ.get("DEFECTDOJO_API_TOKEN"):
        die("DEFECTDOJO_URL and DEFECTDOJO_API_TOKEN must be set.")

    os.umask(0o077)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    try:
        log("Fetching active findings...")
        raw = fetch_paginated("/api/v2/findings/", {"active": "true"})
    except Exception as exc:
        die(f"could not fetch findings: {exc}")

    try:
        test_titles = {
            t["id"]: t.get("test_title") or t.get("scan_type") or "Unknown"
            for t in fetch_paginated("/api/v2/tests/", {})
        }
    except Exception as exc:
        warn(f"could not load test names; scanner column will show Unknown: {exc}")
        test_titles = {}

    findings = [normalize(r, test_titles, base) for r in raw]
    log(f"Retrieved {len(findings)} active finding(s).")

    counts = Counter(f["severity"] for f in findings)
    by_scanner = defaultdict(Counter)
    for f in findings:
        by_scanner[f["scanner"]][f["severity"]] += 1

    eng_id = os.environ.get("DEFECTDOJO_ENGAGEMENT_ID", "")
    ctx = {
        "findings": findings,
        "counts": counts,
        "by_scanner": by_scanner,
        "product": os.environ.get("DEFECTDOJO_PRODUCT_NAME", "DevSecOps Pipeline"),
        "engagement": os.environ.get("DEFECTDOJO_ENGAGEMENT_NAME", "CI Pipeline"),
        "job": os.environ.get("JOB_NAME", "Unknown"),
        "build": os.environ.get("BUILD_NUMBER", "Unknown"),
        "commit": os.environ.get("GIT_COMMIT", "Unknown"),
        "build_url": os.environ.get("BUILD_URL", ""),
        "engagement_url": f"{base}/engagement/{eng_id}" if eng_id else base,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
    }

    doc = build_html(ctx)
    HTML_PATH.write_text(doc, encoding="utf-8")
    log(f"HTML written: {HTML_PATH}")

    if write_pdf(doc):
        log(f"PDF written: {PDF_PATH}")
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()