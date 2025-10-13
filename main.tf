# -----------------------------
# 0️⃣ AWS Provider
# -----------------------------
provider "aws" {
  region = "us-west-2"
}

# -----------------------------
# 1️⃣ Availability Zones
# -----------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------
# 2️⃣ Amazon Linux 2 AMI
# -----------------------------
data "aws_ami" "amazon_linux_2" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  owners = ["amazon"]
}

# -----------------------------
# 3️⃣ VPC Module
# -----------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "learn-hcp-terraform"
  cidr = "10.0.0.0/16"

  azs             = data.aws_availability_zones.available.names
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_dns_hostnames = true
}

# Allow outbound HTTPS from instances to VPC endpoints
resource "aws_security_group_rule" "allow_https_to_endpoints" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.vpc.default_security_group_id
  source_security_group_id = aws_security_group.ssm_endpoints.id
  description              = "Allow HTTPS to SSM VPC endpoints"
}

# -----------------------------
# 4️⃣ S3 Bucket for Kong Packages
# -----------------------------
resource "aws_s3_bucket" "kong_packages" {
  bucket = "kong-packages-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Kong Packages"
    Environment = "Production"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "kong_packages" {
  bucket = aws_s3_bucket.kong_packages.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kong_packages" {
  bucket = aws_s3_bucket.kong_packages.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "kong_packages" {
  bucket = aws_s3_bucket.kong_packages.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------
# 5️⃣ IAM Role for SSM + S3 Access
# -----------------------------
resource "aws_iam_role" "ssm_role" {
  name = "ec2_ssm_s3_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ✨ NEW: S3 Access Policy for Kong Packages
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-kong-packages-access"
  role = aws_iam_role.ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.kong_packages.arn,
          "${aws_s3_bucket.kong_packages.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm-s3-instance-profile"
  role = aws_iam_role.ssm_role.name
}

# -----------------------------
# 6️⃣ Security Group for VPC Endpoints
# -----------------------------
resource "aws_security_group" "ssm_endpoints" {
  name        = "ssm-endpoints-sg"
  description = "Security group attached to SSM interface endpoints"
  vpc_id      = module.vpc.vpc_id

  # Allow inbound HTTPS from the instances' security group (default SG from module)
  ingress {
    description     = "Allow HTTPS from app instances"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.vpc.default_security_group_id]
  }

  # Allow all outbound so endpoint ENIs can talk to AWS services
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ssm-endpoints-sg"
  }
}

# -----------------------------
# 7️⃣ VPC Endpoints for SSM (for private subnet)
# -----------------------------
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-west-2.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-west-2.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.us-west-2.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
}

# ✅ S3 Gateway VPC Endpoint (FREE - allows access to S3 and yum repos)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.us-west-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  # Optional: Restrict to specific bucket(s)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.kong_packages.arn,
          "${aws_s3_bucket.kong_packages.arn}/*",
          "arn:aws:s3:::amazonlinux*",  # Allow access to Amazon Linux repos
          "arn:aws:s3:::amazonlinux*/*"
        ]
      }
    ]
  })

  tags = {
    Name = "s3-gateway-endpoint"
  }
}

# -----------------------------
# 8️⃣ EC2 Instance in Private Subnet with Amazon Linux 2
# -----------------------------
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [module.vpc.default_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  # ensure endpoints are created first
  depends_on = [
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ssmmessages,
    aws_vpc_endpoint.ec2messages,
    aws_vpc_endpoint.s3
  ]

  user_data = <<-EOF
    #!/bin/bash
    # SSM Agent is pre-installed on Amazon Linux 2
    # Just ensure it's running
    systemctl restart amazon-ssm-agent
    systemctl enable amazon-ssm-agent

    # Install AWS CLI v2 (in case it's not already installed)
    yum install -y aws-cli

    # Verification marker
    echo "SSM restarted at $(date -u)" > /var/log/ssm-userdata-marker
    
    # Test S3 access
    aws s3 ls --region us-west-2 > /var/log/s3-test.log 2>&1
  EOF

  tags = {
    Name = var.instance_name
  }
}

# -----------------------------
# 9️⃣ Outputs
# -----------------------------
output "ec2_instance_id" {
  value       = aws_instance.app_server.id
  description = "EC2 Instance ID for SSM Session Manager access"
}

output "ec2_private_ip" {
  value       = aws_instance.app_server.private_ip
  description = "Private IP of the EC2 instance"
}

output "s3_endpoint_id" {
  value       = aws_vpc_endpoint.s3.id
  description = "S3 VPC Endpoint ID"
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.kong_packages.id
  description = "S3 bucket name for Kong packages"
}

output "ssm_connect_command" {
  value       = "aws ssm start-session --target ${aws_instance.app_server.id} --region us-west-2"
  description = "Command to connect to the instance via SSM"
}

output "s3_upload_command" {
  value       = "aws s3 cp ./kong-*.rpm s3://${aws_s3_bucket.kong_packages.id}/ --region us-west-2"
  description = "Command to upload Kong RPM to S3"
}
