"""Flask application factory for the Payments Status API (synthetic demo data)."""

from flask import Flask, jsonify, request

from . import __version__
from .data import PAYMENTS

SERVICE_NAME = "Contoso Bank - Payments Status API"


def summarise(payments):
    """Count payments per status, e.g. {"total": 6, "settled": 3, "pending": 2, "failed": 1}."""
    summary = {"total": len(payments)}
    for payment in payments:
        key = payment["status"].lower()
        summary[key] = summary.get(key, 0) + 1
    return summary


def create_app() -> Flask:
    app = Flask(__name__)

    @app.get("/")
    def index():
        return jsonify(
            service=SERVICE_NAME,
            version=__version__,
            data="synthetic - fictional records only",
            endpoints=["/health", "/api/payments/status"],
        )

    @app.get("/health")
    def health():
        return jsonify(status="ok")

    @app.get("/api/payments/status")
    def payments_status():
        wanted = request.args.get("status", "").strip().lower()
        channel = request.args.get("channel", "").strip().lower()
        records = [
            p
            for p in PAYMENTS
            if (not wanted or p["status"].lower() == wanted)
            and (not channel or p["channel"].lower() == channel)
        ]
        return jsonify(
            currency="NGN",
            synthetic=True,
            summary=summarise(records),
            payments=records,
        )

    return app


app = create_app()
