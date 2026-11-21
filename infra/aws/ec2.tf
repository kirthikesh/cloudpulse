# Single k3s node on Amazon Linux 2023.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_caller_identity" "current" {}

locals {
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  monitoring             = true
  ebs_optimized          = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region       = var.region
    registry     = local.registry
    namespaces   = join(" ", var.environments)
    k3s_channel  = var.k3s_channel
    helm_version = var.helm_version
  })
  user_data_replace_on_change = true

  # IMDSv2 only. Hop limit 2 so pods (one network hop away) can still get the node role credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project}-k3s"
    Role = "k3s-node" # the pipeline finds the node by this tag
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the node every time AWS publishes a new AMI
  }
}

resource "aws_eip" "node" {
  domain   = "vpc"
  instance = aws_instance.node.id
  tags     = { Name = "${var.project}-eip" }
}
