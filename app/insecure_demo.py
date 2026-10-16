"""DEMO ONLY - a deliberately vulnerable endpoint (SQL injection). Synthetic data. Never copy this pattern.

The SQL text below is built by joining strings, so a request such as  ?ref=' OR '1'='1  changes the meaning
of the query. CodeQL reports it on the pull request and Copilot Autofix proposes the parameterised version.
"""

import sqlite3

from flask import Blueprint, jsonify, request

from .data import PAYMENTS

insecure_demo = Blueprint("insecure_demo", __name__)

COLUMNS = ("reference", "beneficiary", "status")


def _demo_database() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.execute("CREATE TABLE payments (reference TEXT, beneficiary TEXT, status TEXT)")
    connection.executemany(
        "INSERT INTO payments VALUES (?, ?, ?)",
        [(p["reference"], p["beneficiary"], p["status"]) for p in PAYMENTS],
    )
    return connection


@insecure_demo.get("/api/demo/insecure-search")
def insecure_search():
    reference = request.args.get("ref", "")
    cursor = _demo_database().cursor()
    cursor.execute("SELECT reference, beneficiary, status FROM payments WHERE reference = '" + reference + "'")
    matches = [dict(zip(COLUMNS, row)) for row in cursor.fetchall()]
    return jsonify(synthetic=True, matches=matches)
