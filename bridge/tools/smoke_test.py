from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient

import main
import rss_store

client = TestClient(main.app)

assert client.get("/missions").status_code == 401

main.SESSIONS["test"] = {
    "username": "teste",
    "cookies": {},
    "csrf": "x",
    "created_at": "x",
    "last_seen": "x",
}
headers = {"Authorization": "Bearer test"}

dashboard = client.get("/missions/1/dashboard", headers=headers)
assert dashboard.status_code == 200
assert dashboard.json()["total_tasks"] == 205
assert dashboard.json()["work_total"] == 73
assert dashboard.json()["overall_total"] == 278

work_items = client.get("/missions/1/work-items", headers=headers)
assert work_items.status_code == 200
assert work_items.json()["total"] == 73

p0 = client.get("/missions/1/tasks?priority=P0", headers=headers)
assert p0.status_code == 200
assert p0.json()["total"] == 8

opportunities = client.get("/opportunities/dashboard", headers=headers)
assert opportunities.status_code == 200

blocked = False
try:
    rss_store._validate_public_url("http://127.0.0.1")
except ValueError:
    blocked = True
assert blocked

print(
    "MISSION_API_OK",
    dashboard.json()["total_tasks"],
    "P0",
    p0.json()["total"],
    "RSS_PRIVATE_BLOCK_OK",
)
