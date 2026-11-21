"""DynamoDB single-table store.

Layout (table keys: pk, sk):
  pk = "MON#<id>", sk = "META"            -> monitor definition + last status
  pk = "MON#<id>", sk = "CHECK#<iso-ts>"  -> one check result (expires via TTL)
"""

import time
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key

from .config import Settings


def _now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _clean(item: dict) -> dict:
    """Convert DynamoDB Decimals back to int/float for JSON."""
    out = {}
    for k, v in item.items():
        if isinstance(v, Decimal):
            out[k] = int(v) if v == v.to_integral_value() else float(v)
        else:
            out[k] = v
    return out


class Store:
    def __init__(self, settings: Settings):
        self.settings = settings
        resource = boto3.resource(
            "dynamodb",
            region_name=settings.aws_region,
            endpoint_url=settings.dynamodb_endpoint,
        )
        self.table = resource.Table(settings.table_name)

    def ping(self) -> bool:
        self.table.load()
        return True

    # ---- monitors ----
    def create_monitor(self, name: str, url: str) -> dict:
        monitor_id = uuid.uuid4().hex[:12]
        item = {
            "pk": f"MON#{monitor_id}",
            "sk": "META",
            "id": monitor_id,
            "name": name,
            "url": url,
            "created_at": _now_iso(),
            "status": "pending",
        }
        self.table.put_item(Item=item)
        return self._public(item)

    def list_monitors(self) -> list[dict]:
        items, kwargs = [], {"FilterExpression": Attr("sk").eq("META")}
        while True:
            resp = self.table.scan(**kwargs)
            items.extend(resp.get("Items", []))
            if "LastEvaluatedKey" not in resp:
                break
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        return sorted((self._public(i) for i in items), key=lambda m: m["created_at"])

    def get_monitor(self, monitor_id: str) -> dict | None:
        resp = self.table.get_item(Key={"pk": f"MON#{monitor_id}", "sk": "META"})
        item = resp.get("Item")
        return self._public(item) if item else None

    def delete_monitor(self, monitor_id: str) -> bool:
        if not self.get_monitor(monitor_id):
            return False
        resp = self.table.query(KeyConditionExpression=Key("pk").eq(f"MON#{monitor_id}"))
        with self.table.batch_writer() as batch:
            for item in resp.get("Items", []):
                batch.delete_item(Key={"pk": item["pk"], "sk": item["sk"]})
        return True

    # ---- check results ----
    def record_check(
        self, monitor_id: str, up: bool, status_code: int | None, latency_ms: float, error: str | None = None
    ) -> dict:
        ts = _now_iso()
        result = {
            "checked_at": ts,
            "up": up,
            "status_code": status_code if status_code is not None else 0,
            "latency_ms": Decimal(str(round(latency_ms, 1))),
        }
        if error:
            result["error"] = error[:200]
        ttl = int(time.time()) + self.settings.result_ttl_days * 86400
        self.table.put_item(Item={"pk": f"MON#{monitor_id}", "sk": f"CHECK#{ts}", "ttl": ttl, **result})
        self.table.update_item(
            Key={"pk": f"MON#{monitor_id}", "sk": "META"},
            UpdateExpression="SET #s = :s, last_checked_at = :t, last_latency_ms = :l, last_status_code = :c",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "up" if up else "down",
                ":t": ts,
                ":l": result["latency_ms"],
                ":c": result["status_code"],
            },
        )
        return _clean(result)

    def list_checks(self, monitor_id: str, limit: int = 30) -> list[dict]:
        resp = self.table.query(
            KeyConditionExpression=Key("pk").eq(f"MON#{monitor_id}") & Key("sk").begins_with("CHECK#"),
            ScanIndexForward=False,
            Limit=limit,
        )
        return [_clean({k: v for k, v in i.items() if k not in ("pk", "sk", "ttl")}) for i in resp.get("Items", [])]

    @staticmethod
    def _public(item: dict) -> dict:
        return _clean({k: v for k, v in item.items() if k not in ("pk", "sk")})
