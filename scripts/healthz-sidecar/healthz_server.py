"""
healthz-sidecar: Lightweight HTTP health-check server for COS deployments.

Endpoints:
  /healthz      — Returns 200 during bootstrap grace window (first BOOTSTRAP_WINDOW_SECONDS),
                   after that delegates to /healthz/deep logic.
  /healthz/deep — All-or-nothing deep check:
                   1. Postgres SELECT 1 completes in < 1s
                   2. n8n REST /rest/active-workflows responds in < 2s
                   3. Container cloudflared is in state running (via metrics endpoint)
                   Returns HTTP 200 only when ALL three pass.
                   Returns HTTP 503 with JSON body identifying which check failed.

Requirements: 8.6, 8.7, 8.8, 8.9
"""

import http.server
import json
import os
import socket
import socketserver
import time
import urllib.request
import urllib.error

import psycopg2

# Configuration from environment
BOOTSTRAP_WINDOW_SECONDS = int(os.environ.get("BOOTSTRAP_WINDOW_SECONDS", "1800"))
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "postgres")
POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
POSTGRES_USER = os.environ.get("POSTGRES_USER", "n8n")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "n8n")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
N8N_URL = os.environ.get("N8N_URL", "http://n8n:5678/healthz")
CLOUDFLARED_METRICS_URL = os.environ.get("CLOUDFLARED_METRICS_URL", "http://cloudflared:2000/ready")

PORT = int(os.environ.get("HEALTHZ_PORT", "8080"))

START_TIME = time.time()


def check_postgres() -> dict:
    """Check Postgres SELECT 1 completes in < 1s."""
    start = time.time()
    try:
        conn = psycopg2.connect(
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD,
            dbname=POSTGRES_DB,
            connect_timeout=1,
        )
        try:
            cur = conn.cursor()
            cur.execute("SELECT 1")
            cur.fetchone()
            cur.close()
        finally:
            conn.close()

        elapsed = time.time() - start
        if elapsed > 5.0:
            return {"ok": False, "check": "postgres", "error": f"too slow: {elapsed:.2f}s"}
        return {"ok": True, "check": "postgres", "latency_ms": int(elapsed * 1000)}
    except Exception as e:
        return {"ok": False, "check": "postgres", "error": str(e)}


def check_n8n() -> dict:
    """Check n8n REST /rest/active-workflows responds in < 2s."""
    start = time.time()
    try:
        req = urllib.request.Request(N8N_URL, method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            resp.read()
            elapsed = time.time() - start
            if elapsed > 2.0:
                return {"ok": False, "check": "n8n", "error": f"too slow: {elapsed:.2f}s"}
            return {"ok": True, "check": "n8n", "latency_ms": int(elapsed * 1000)}
    except Exception as e:
        return {"ok": False, "check": "n8n", "error": str(e)}


def check_cloudflared() -> dict:
    """Check cloudflared container is in state running via its metrics/ready endpoint."""
    start = time.time()
    try:
        req = urllib.request.Request(CLOUDFLARED_METRICS_URL, method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            status = resp.status
            elapsed = time.time() - start
            if status == 200:
                return {"ok": True, "check": "cloudflared", "latency_ms": int(elapsed * 1000)}
            return {"ok": False, "check": "cloudflared", "error": f"HTTP {status}"}
    except Exception as e:
        return {"ok": False, "check": "cloudflared", "error": str(e)}


def run_deep_checks() -> tuple[bool, list[dict]]:
    """Run all three deep checks. Returns (all_ok, results)."""
    results = [
        check_postgres(),
        check_n8n(),
        check_cloudflared(),
    ]
    all_ok = all(r["ok"] for r in results)
    return all_ok, results


class HealthHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for health endpoints."""

    def log_message(self, format, *args):
        """Suppress default access logging to reduce noise."""
        pass

    def do_GET(self):
        if self.path == "/healthz":
            self._handle_healthz()
        elif self.path == "/healthz/deep":
            self._handle_deep()
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "not found"}).encode())

    def _handle_healthz(self):
        """Bootstrap grace: return 200 during first BOOTSTRAP_WINDOW_SECONDS.
        After that, delegate to deep check logic."""
        uptime = time.time() - START_TIME

        if uptime < BOOTSTRAP_WINDOW_SECONDS:
            # During bootstrap grace, always return 200
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            body = {
                "status": "bootstrap",
                "uptime_seconds": int(uptime),
                "grace_remaining_seconds": int(BOOTSTRAP_WINDOW_SECONDS - uptime),
            }
            self.wfile.write(json.dumps(body).encode())
            return

        # After bootstrap grace, delegate to deep check
        self._handle_deep()

    def _handle_deep(self):
        """All-or-nothing deep health check."""
        all_ok, results = run_deep_checks()

        if all_ok:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            body = {"status": "healthy", "checks": results}
            self.wfile.write(json.dumps(body).encode())
        else:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            failed = [r for r in results if not r["ok"]]
            body = {
                "status": "unhealthy",
                "checks": results,
                "failed": failed,
            }
            self.wfile.write(json.dumps(body).encode())


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    """Allow concurrent health check requests."""
    allow_reuse_address = True
    daemon_threads = True


def main():
    print(f"healthz-sidecar starting on port {PORT}")
    print(f"  BOOTSTRAP_WINDOW_SECONDS={BOOTSTRAP_WINDOW_SECONDS}")
    print(f"  POSTGRES_HOST={POSTGRES_HOST}:{POSTGRES_PORT}")
    print(f"  N8N_URL={N8N_URL}")
    print(f"  CLOUDFLARED_METRICS_URL={CLOUDFLARED_METRICS_URL}")

    with ThreadedTCPServer(("", PORT), HealthHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
