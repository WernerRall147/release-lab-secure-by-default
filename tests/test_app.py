import pytest

from app import __version__
from app.main import SERVICE_NAME, create_app


@pytest.fixture()
def client():
    return create_app().test_client()


def test_index_describes_the_service(client):
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_json()
    assert body["service"] == SERVICE_NAME
    assert body["version"] == __version__
    assert "synthetic" in body["data"]


def test_health_is_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_payment_status_returns_synthetic_naira_records(client):
    response = client.get("/api/payments/status")
    assert response.status_code == 200
    body = response.get_json()
    assert body["currency"] == "NGN"
    assert body["synthetic"] is True
    assert len(body["payments"]) == body["summary"]["total"] > 0
    for payment in body["payments"]:
        assert payment["reference"].startswith("PAY-")
        assert payment["amount_ngn"] > 0


def test_payment_status_summary_matches_records(client):
    body = client.get("/api/payments/status").get_json()
    counted = sum(v for k, v in body["summary"].items() if k != "total")
    assert counted == body["summary"]["total"]


@pytest.mark.parametrize("status", ["settled", "PENDING", "Failed"])
def test_payment_status_can_be_filtered(client, status):
    body = client.get("/api/payments/status", query_string={"status": status}).get_json()
    assert body["payments"], "the synthetic data set contains every status"
    assert {p["status"] for p in body["payments"]} == {status.upper()}


def test_unknown_status_filter_returns_empty_list(client):
    body = client.get("/api/payments/status", query_string={"status": "nope"}).get_json()
    assert body["payments"] == []
    assert body["summary"] == {"total": 0}


def test_unknown_route_returns_404(client):
    assert client.get("/does-not-exist").status_code == 404
