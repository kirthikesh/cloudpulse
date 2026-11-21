import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

os.environ.update(
    {
        "CLOUDPULSE_NO_AUTOAPP": "1",
        "TABLE_NAME": "cloudpulse-test",
        "AWS_REGION": "eu-west-1",
        "AWS_DEFAULT_REGION": "eu-west-1",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "ROLE": "api",  # no background checker during tests
        "APP_ENV": "test",
    }
)


@pytest.fixture
def store():
    with mock_aws():
        boto3.client("dynamodb", region_name="eu-west-1").create_table(
            TableName="cloudpulse-test",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        from cloudpulse.config import get_settings
        from cloudpulse.store import Store

        yield Store(get_settings())


@pytest.fixture
def client(store):
    from fastapi.testclient import TestClient

    from cloudpulse.main import create_app

    with TestClient(create_app(store)) as c:
        yield c
