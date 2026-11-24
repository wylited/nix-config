#!/usr/bin/env python3
"""dash-proxy — metrics for dash.ts.wyli.tech.

Serves JSON on the tailnet for warden's Caddy to proxy as /proxy/*:

  GET /status   -> egress month-to-date + mihomo delay
  GET /healthz  -> "ok"

Egress source: GCP Monitoring
`compute.googleapis.com/instance/network/sent_bytes_count`, summed over all GCE
instances in the project for the current UTC month. It is the same metric
family GCP bills from, so use it as the practical figure: it includes some
free Google traffic and under-reads the NIC by roughly 0.1 GB/month, and it
does not subtract the 1 GiB free allowance (the script does). The metric
survives instance replacement for the retention window, so a recreated ranger
does not reset the month. GCP ingestion lags by ~4 minutes.

Delay source: mihomo's own probe for the `ranger-in` proxy. This is the real
client-side proxy delay, not a TCP RTT.

Runs as the logged-in user because it needs that user's gcloud ADC. No third-
party Python packages.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = os.environ.get("GCP_PROJECT", "fluted-helper-326503")
METRIC_FILTER = (
    'metric.type="compute.googleapis.com/instance/network/sent_bytes_count" '
    'AND resource.type="gce_instance"'
)
FREE_BYTES = 1024**3
BILLABLE_BUDGET_GB = 17.0
USD_PER_GIB = 0.12
MIHOMO_DELAY_URL = (
    "http://127.0.0.1:9090/proxies/ranger-in/delay"
    "?timeout=5000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
)

_lock = threading.Lock()
_token: tuple[str, float] | None = None  # (token, monotonic expiry)
_egress_cache: tuple[float, dict] | None = None
_egress_last: dict | None = None


def _gcloud() -> str:
    candidates = [
        os.environ.get("GCLOUD"),
        "/run/current-system/sw/bin/gcloud",
        "/etc/profiles/per-user/wyli/bin/gcloud",
        shutil.which("gcloud"),
    ]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise RuntimeError("gcloud not found")


def access_token(force: bool = False) -> str:
    global _token
    with _lock:
        now = time.monotonic()
        if not force and _token and _token[1] > now:
            return _token[0]
        env = dict(os.environ)
        env.setdefault("HOME", "/Users/wyli")
        out = subprocess.run(
            [_gcloud(), "auth", "application-default", "print-access-token"],
            check=True,
            capture_output=True,
            text=True,
            timeout=25,
            env=env,
        )
        token = out.stdout.strip()
        if not token:
            raise RuntimeError("empty ADC token")
        _token = (token, now + 45 * 60)
        return token


def _monitoring(token: str, url: str) -> dict:
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as res:
        return json.load(res)


def egress() -> dict:
    global _egress_cache, _egress_last
    now_mono = time.monotonic()
    if _egress_cache and _egress_cache[0] > now_mono:
        return _egress_cache[1]

    now = datetime.now(timezone.utc)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    params = {
        "filter": METRIC_FILTER,
        "interval.startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "interval.endTime": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "aggregation.alignmentPeriod": "3600s",
        "aggregation.perSeriesAligner": "ALIGN_SUM",
        "aggregation.crossSeriesReducer": "REDUCE_SUM",
    }
    url = (
        f"https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?"
        + urllib.parse.urlencode(params)
    )

    try:
        try:
            payload = _monitoring(access_token(), url)
        except urllib.error.HTTPError as err:
            if err.code != 401:
                raise
            payload = _monitoring(access_token(force=True), url)

        total = 0
        for series in payload.get("timeSeries", []):
            for point in series.get("points", []):
                value = point.get("value", {})
                total += int(value.get("int64Value", 0))
                if "doubleValue" in value:
                    total += int(float(value["doubleValue"]))

        billable = max(0, total - FREE_BYTES)
        gib = 1024**3
        result = {
            "month": start.strftime("%Y-%m"),
            "total_bytes": total,
            "total_gb": round(total / gib, 3),
            "free_gb": 1.0,
            "billable_bytes": billable,
            "billable_gb": round(billable / gib, 3),
            "budget_gb": BILLABLE_BUDGET_GB,
            "pct": round(min(100.0, (billable / gib) / BILLABLE_BUDGET_GB * 100), 1),
            "cost_usd": round((billable / gib) * USD_PER_GIB, 2),
            "estimated": True,
        }
        _egress_last = result
        _egress_cache = (now_mono + 120, result)
        return result
    except Exception as err:  # keep the last good sample; the page shows its age
        if _egress_last:
            return {**_egress_last, "error": str(err), "stale": True}
        return {"error": str(err), "estimated": True}


def delay() -> tuple[int | None, str | None]:
    try:
        with urllib.request.urlopen(MIHOMO_DELAY_URL, timeout=8) as res:
            data = json.load(res)
        value = data.get("delay")
        if isinstance(value, int) and value > 0:
            return value, None
        return None, str(data.get("message") or "no delay")
    except urllib.error.HTTPError as err:
        try:
            body = err.read().decode("utf-8", "replace")
            message = json.loads(body).get("message")
        except Exception:
            message = None
        return None, message or f"HTTP {err.code}"
    except Exception as err:
        return None, str(err)


class Handler(BaseHTTPRequestHandler):
    server_version = "dash-proxy/1"

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
            return
        if path != "/status":
            self._send(404, b"not found\n", "text/plain; charset=utf-8")
            return

        delay_ms, delay_error = delay()
        body = json.dumps(
            {
                "egress": egress(),
                "delay_ms": delay_ms,
                "delay_error": delay_error,
                "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            separators=(",", ":"),
        ).encode()
        self._send(200, body, "application/json")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="100.84.47.44", help="tailnet bind address")
    parser.add_argument("--port", type=int, default=9091)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"dash-proxy listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
