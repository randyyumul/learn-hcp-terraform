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
# 4️⃣ IAM Role for SSM
# -----------------------------
resource "aws_iam_role" "ssm_role" {
  name = "ec2_ssm_role"
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

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm-instance-profile"
  role = aws_iam_role.ssm_role.name
}

# -----------------------------
# 5️⃣ Security Group for VPC Endpoints
# -----------------------------
resource "aws_security_group" "ssm_endpoints" {
  name        = "ssm-endpoints-sg"
  description = "Security group attached to SSM interface endpoints"
  vpc_id      = module.vpc.vpc_id

  # Allow inbound HTTPS from the instances' security group (default SG from module)
  ingress {
    description  = "Allow HTTPS from app instances"
    from_port    = 443
    to_port      = 443
    protocol     = "tcp"
    # allow from the instances' SG. If you later use a custom SG for instances, replace this.
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
# 6️⃣ VPC Endpoints for SSM (for private subnet)
# -----------------------------
resource "aws_vpc_endpoint" "ssm" {
  vpc_id               = module.vpc.vpc_id
  service_name         = "com.amazonaws.us-west-2.ssm"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled  = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id               = module.vpc.vpc_id
  service_name         = "com.amazonaws.us-west-2.ssmmessages"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled  = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id               = module.vpc.vpc_id
  service_name         = "com.amazonaws.us-west-2.ec2messages"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled  = true
}

# -----------------------------
# 7️⃣ EC2 Instance in Private Subnet with Amazon Linux 2
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
    aws_vpc_endpoint.ec2messages
  ]

user_data = <<-EOF
  #!/bin/bash
  # SSM Agent is pre-installed on Amazon Linux 2
  # Just ensure it's running
  systemctl restart amazon-ssm-agent
  systemctl enable amazon-ssm-agent

  # Verification marker
  echo "SSM restarted at $(date -u)" > /var/log/ssm-userdata-marker
  EOF

  tags = {
    Name = var.instance_name
  }
}

# -----------------------------
# 8️⃣ Outputs
# -----------------------------
output "ec2_instance_id" {
  value = aws_instance.app_server.id
}

output "ec2_private_ip" {
  value = aws_instance.app_server.private_ip
}

