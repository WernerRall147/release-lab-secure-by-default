from app.main import create_app


def test_insecure_search_finds_a_known_reference():
    client = create_app().test_client()
    response = client.get("/api/demo/insecure-search", query_string={"ref": "PAY-100001"})
    assert response.status_code == 200
    assert [m["reference"] for m in response.get_json()["matches"]] == ["PAY-100001"]
