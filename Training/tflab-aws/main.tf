terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.8" # 5.8+ required for aws_ec2_instance_connect_endpoint
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  common_tags = {
    owner = "training"
  }
}

# ─── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.common_tags, { Name = "vpc-ailab" })
}

# ─── Subnets ───────────────────────────────────────────────────────────────────

# Public subnet — hosts the NAT Gateway only (no VMs)
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.0.0/28"
  availability_zone = var.availability_zone
  tags              = merge(local.common_tags, { Name = "snet-public" })
}

# App subnet — vm-app (10.0.1.10) and vm-win (10.0.1.20)
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = var.availability_zone
  tags              = merge(local.common_tags, { Name = "snet-app" })
}

# DB subnet — vm-db (10.0.2.10)
resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.availability_zone
  tags              = merge(local.common_tags, { Name = "snet-db" })
}

# EICE subnet — EC2 Instance Connect Endpoint (equivalent to AzureBastionSubnet)
resource "aws_subnet" "eice" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.3.0/27"
  availability_zone = var.availability_zone
  tags              = merge(local.common_tags, { Name = "snet-eice" })
}

# ─── Internet Gateway & NAT Gateway ────────────────────────────────────────────
# Required so private-subnet VMs can reach the internet for package installs
# (mirrors Azure's default outbound internet access for VMs)

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.common_tags, { Name = "igw-ailab" })
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  tags       = merge(local.common_tags, { Name = "eip-nat" })
  depends_on = [aws_internet_gateway.lab]
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = merge(local.common_tags, { Name = "nat-ailab" })
  depends_on    = [aws_internet_gateway.lab]
}

# ─── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = merge(local.common_tags, { Name = "rt-public" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = merge(local.common_tags, { Name = "rt-private" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "eice" {
  subnet_id      = aws_subnet.eice.id
  route_table_id = aws_route_table.private.id
}

# ─── Security Groups ───────────────────────────────────────────────────────────

# EICE security group — governs what traffic the endpoint may initiate outbound
resource "aws_security_group" "eice" {
  name        = "sg-eice"
  description = "Outbound SSH and RDP from EC2 Instance Connect Endpoint"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "AllowSSH to app subnet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    description = "AllowRDP to app subnet"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  tags = merge(local.common_tags, { Name = "sg-eice" })
}

# App security group — applied to vm-app and vm-win
# Equivalent to nsg-app; source is sg-eice instead of bastion subnet CIDR
resource "aws_security_group" "app" {
  name        = "sg-app"
  description = "Allow SSH and RDP from EICE only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description     = "AllowSSH from EICE"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  ingress {
    description     = "AllowRDP from EICE"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "sg-app" })
}

# DB security group — equivalent to nsg-db
resource "aws_security_group" "db" {
  name        = "sg-db"
  description = "Allow PostgreSQL from app subnet only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "AllowPostgres from app subnet"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "sg-db" })
}

# ─── EC2 Instance Connect Endpoint (replaces Azure Bastion) ───────────────────
# Connect via: aws ec2-instance-connect ssh --instance-id <id> --endpoint-id <eice_id>
# RDP tunnel:  aws ec2-instance-connect open-tunnel --instance-id <id> --remote-port 3389 --local-port 13389

resource "aws_ec2_instance_connect_endpoint" "lab" {
  subnet_id          = aws_subnet.eice.id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = true
  tags               = merge(local.common_tags, { Name = "eice-ailab" })
}

# ─── AMI Data Sources ──────────────────────────────────────────────────────────

# Ubuntu 22.04 LTS (equivalent to 0001-com-ubuntu-server-jammy 22_04-lts-gen2)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Windows Server 2022 (equivalent to WindowsServer 2022-datacenter-azure-edition)
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Key Pair ──────────────────────────────────────────────────────────────────
# Replaces password authentication. For Windows, the key decrypts the
# auto-generated Administrator password (EC2 Console → Get Windows Password).

resource "aws_key_pair" "lab" {
  key_name   = "key-ailab-${var.participant_name}"
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# ─── Virtual Machines ──────────────────────────────────────────────────────────

# vm-app — Ubuntu 22.04, t3.large (2 vCPU / 8 GiB) ≈ Standard_B2ms
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.10"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  monitoring             = true # detailed CloudWatch monitoring — replaces boot diagnostics

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "vm-app" })
}

# vm-db — Ubuntu 22.04, t3.large (2 vCPU / 8 GiB) ≈ Standard_B2ms
resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.db.id
  private_ip             = "10.0.2.10"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.db.id]
  monitoring             = true
  user_data              = file("${path.module}/cloud-init-db.yaml")

  root_block_device {
    volume_type = "gp2"
    volume_size = 30
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "vm-db" })
}

# vm-win — Windows Server 2022, t3.medium (2 vCPU / 4 GiB) ≈ Standard_B2s
resource "aws_instance" "win" {
  ami                    = data.aws_ami.windows.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.20"
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  monitoring             = true

  root_block_device {
    volume_type = "gp2"
    volume_size = 128
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "vm-win" })
}

# ─── S3 Bucket (replaces Azure Storage Account) ────────────────────────────────

resource "aws_s3_bucket" "lab" {
  bucket = "s3-ailab-${var.participant_name}"
  tags   = merge(local.common_tags, { Name = "s3-ailab-${var.participant_name}" })
}

# Versioning — enables soft-delete semantics (overwrite/delete = new version, not permanent loss)
resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle — expire non-current versions after 30 days (equivalent to soft-delete retention)
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  bucket     = aws_s3_bucket.lab.id
  depends_on = [aws_s3_bucket_versioning.lab]

  rule {
    id     = "soft-delete-retention"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# Server-side encryption with S3-managed keys
resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access (equivalent to allow_nested_items_to_be_public = false)
resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs — enforce bucket-owner-only access via bucket policy
resource "aws_s3_bucket_ownership_controls" "lab" {
  bucket = aws_s3_bucket.lab.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ─── Auto-Shutdown via EventBridge Scheduler (replaces Dev Test VM Shutdown) ───
# Stops all three VMs daily at 13:00 UTC, equivalent to daily_recurrence_time = "1300"

resource "aws_iam_role" "scheduler" {
  name = "role-scheduler-stop-vms-${var.participant_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler_stop_ec2" {
  name = "policy-stop-ec2"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = "*"
    }]
  })
}

resource "aws_scheduler_schedule" "app" {
  name = "stop-vm-app-${var.participant_name}"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 13 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.app.id] })
  }
}

resource "aws_scheduler_schedule" "db" {
  name = "stop-vm-db-${var.participant_name}"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 13 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.db.id] })
  }
}

resource "aws_scheduler_schedule" "win" {
  name = "stop-vm-win-${var.participant_name}"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 13 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.win.id] })
  }
}
