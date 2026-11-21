# One on-demand table per environment. Pay-per-request stays inside the free tier for this workload.

resource "aws_dynamodb_table" "app" {
  for_each     = toset(var.environments)
  name         = "${var.project}-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Old check results expire automatically
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = each.key == "prod"
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = false # set true for a real prod

  tags = { Environment = each.key }
}
