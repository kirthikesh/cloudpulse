# ---------------------------------------------------------------------------
# 1) Instance role for the k3s node
#    - SSM agent (so Azure DevOps can deploy with no SSH and no open k8s API)
#    - pull images/charts from ECR
#    - read/write the app's DynamoDB tables (pods use the node role through IMDSv2)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "dynamodb_app" {
  statement {
    sid = "AppTables"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [for t in aws_dynamodb_table.app : t.arn]
  }
}

resource "aws_iam_role_policy" "dynamodb_app" {
  name   = "dynamodb-app-tables"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.dynamodb_app.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-node"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# 2) Least-privilege IAM user for the Azure DevOps *app* pipeline
#    Can only: push to the two ECR repos, find the node, run SSM commands on it.
#    Access keys are NOT created here (they would land in state) -
#    create them in the console and paste them into the ADO service connection.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "azure_devops" {
  name = "${var.project}-azure-devops"
}

data "aws_iam_policy_document" "azure_devops" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid       = "FindNode"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid     = "DeployViaSsm"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.node.arn,
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    sid       = "ReadSsmResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }

  statement {
    sid       = "WhoAmI"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "azure_devops" {
  name   = "cloudpulse-app-pipeline"
  user   = aws_iam_user.azure_devops.name
  policy = data.aws_iam_policy_document.azure_devops.json
}
