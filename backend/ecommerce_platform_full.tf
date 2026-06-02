###############################################################################
# ecommerce_platform_infra.tf
#
# Terraform configuration for a production e-commerce platform on AWS.
# Provisions: VPC/networking, web tier (ALB + EC2), application tier,
# RDS (PostgreSQL), S3 (assets + backups), IAM, Lambda (order processor),
# KMS, ElastiCache (Redis), and CloudWatch logging.
#
# Environment: production
# Owner:       platform-engineering@company.com
###############################################################################
 
terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
 
provider "aws" {
  region     = "us-east-1"
  access_key = "AKIAIOSFODNN7EXAMPLE3"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}
 
###############################################################################
# VARIABLES
###############################################################################
 
variable "environment" {
  description = "Deployment environment"
  default     = "production"
}
 
variable "app_name" {
  description = "Application name prefix"
  default     = "ecom"
}
 
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}
 
###############################################################################
# NETWORKING — VPC, Subnets, Gateways
###############################################################################
 
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
 
  tags = {
    Name        = "${var.app_name}-vpc"
    Environment = var.environment
  }
}
 
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
 
  tags = { Name = "${var.app_name}-igw" }
}
 
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
 
  tags = { Name = "${var.app_name}-public-a", Tier = "public" }
}
 
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
 
  tags = { Name = "${var.app_name}-public-b", Tier = "public" }
}
 
resource "aws_subnet" "private_app_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "us-east-1a"
 
  tags = { Name = "${var.app_name}-private-app-a", Tier = "app" }
}
 
resource "aws_subnet" "private_db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = "us-east-1a"
 
  tags = { Name = "${var.app_name}-private-db-a", Tier = "database" }
}
 
resource "aws_subnet" "private_db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "us-east-1b"
 
  tags = { Name = "${var.app_name}-private-db-b", Tier = "database" }
}
 
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
 
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
 
  tags = { Name = "${var.app_name}-public-rt" }
}
 
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
 
resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}
 
###############################################################################
# SECURITY GROUPS
###############################################################################
 
# ALB — public-facing HTTPS + HTTP
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Application Load Balancer security group"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = { Name = "${var.app_name}-alb-sg" }
}
 
# Bastion / ops — SSH wide open to the internet
resource "aws_security_group" "bastion" {
  name        = "${var.app_name}-bastion-sg"
  description = "Bastion host for operations access"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    description = "SSH from everywhere — TODO: restrict before go-live"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  ingress {
    description = "RDP for Windows admin"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = { Name = "${var.app_name}-bastion-sg" }
}
 
# App tier — internal only
resource "aws_security_group" "app" {
  name        = "${var.app_name}-app-sg"
  description = "Application server security group"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    description     = "Traffic from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = { Name = "${var.app_name}-app-sg" }
}
 
# RDS — database security group
resource "aws_security_group" "rds" {
  name        = "${var.app_name}-rds-sg"
  description = "RDS PostgreSQL security group"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    description     = "PostgreSQL from app tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
 
  tags = { Name = "${var.app_name}-rds-sg" }
}
 
###############################################################################
# COMPUTE — Application Load Balancer + EC2
###############################################################################
 
resource "aws_lb" "web" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
 
  tags = { Name = "${var.app_name}-alb", Environment = var.environment }
}
 
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-0-2015-04"  # outdated TLS policy
 
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
 
resource "aws_lb_target_group" "app" {
  name     = "${var.app_name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
 
  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}
 
resource "aws_instance" "app_server" {
  ami                    = "ami-0c55b159cbfafe1f0"
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private_app_a.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app_profile.name
 
  user_data = <<-EOF
    #!/bin/bash
    export DB_PASSWORD="SuperSecret123!"
    export STRIPE_API_KEY="sk_live_51ExampleKeyHardcodedInUserData"
    export REDIS_AUTH_TOKEN="redis-secret-token-hardcoded"
    /opt/app/start.sh
  EOF
 
  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = false
  }
 
  tags = {
    Name        = "${var.app_name}-app-server"
    Environment = var.environment
  }
}
 
resource "aws_instance" "bastion" {
  ami                         = "ami-0c55b159cbfafe1f0"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  key_name                    = "prod-bastion-key"
 
  tags = {
    Name        = "${var.app_name}-bastion"
    Environment = var.environment
  }
}
 
###############################################################################
# DATABASE — RDS PostgreSQL
###############################################################################
 
resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]
 
  tags = { Name = "${var.app_name}-db-subnet-group" }
}
 
resource "aws_db_instance" "postgres" {
  identifier             = "${var.app_name}-postgres"
  engine                 = "postgres"
  engine_version         = "14.7"
  instance_class         = "db.t3.medium"
  allocated_storage      = 100
  storage_encrypted      = false
  db_name                = "ecommerce"
  username               = "dbadmin"
  password               = "Passw0rd!Production2024"
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  deletion_protection    = false
  backup_retention_period = 0
 
  tags = {
    Name        = "${var.app_name}-postgres"
    Environment = var.environment
  }
}
 
###############################################################################
# STORAGE — S3 Buckets
###############################################################################
 
resource "aws_s3_bucket" "assets" {
  bucket = "${var.app_name}-product-assets-prod"
 
  tags = {
    Name        = "${var.app_name}-product-assets"
    Environment = var.environment
  }
}
 
resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
 
resource "aws_s3_bucket_policy" "assets_public_read" {
  bucket = aws_s3_bucket.assets.id
 
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.assets.arn}/*"
      }
    ]
  })
}
 
resource "aws_s3_bucket" "backups" {
  bucket = "${var.app_name}-database-backups-prod"
 
  tags = {
    Name        = "${var.app_name}-db-backups"
    Environment = var.environment
  }
}
 
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}
 
###############################################################################
# IAM — Roles, Policies, Instance Profiles
###############################################################################
 
resource "aws_iam_role" "app_role" {
  name = "${var.app_name}-app-role"
 
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}
 
# Overly permissive policy — full admin access granted to app role
resource "aws_iam_role_policy" "app_admin_policy" {
  name = "${var.app_name}-app-admin"
  role = aws_iam_role.app_role.id
 
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      }
    ]
  })
}
 
resource "aws_iam_instance_profile" "app_profile" {
  name = "${var.app_name}-app-instance-profile"
  role = aws_iam_role.app_role.name
}
 
resource "aws_iam_role" "lambda_role" {
  name = "${var.app_name}-lambda-order-role"
 
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}
 
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
 
# Lambda also gets full S3 access
resource "aws_iam_role_policy" "lambda_s3_full" {
  name = "${var.app_name}-lambda-s3-full"
  role = aws_iam_role.lambda_role.id
 
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      }
    ]
  })
}
 
###############################################################################
# LAMBDA — Order Processing Function
###############################################################################
 
resource "aws_lambda_function" "order_processor" {
  function_name = "${var.app_name}-order-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  filename      = "order_processor.zip"
  timeout       = 30
  memory_size   = 256
 
  environment {
    variables = {
      DB_HOST         = aws_db_instance.postgres.address
      DB_PASSWORD     = "Passw0rd!Production2024"
      STRIPE_SECRET   = "sk_live_51ExampleStripeProductionKey"
      SENDGRID_APIKEY = "SG.ExampleSendgridApiKeyHardcoded123"
      REDIS_URL       = "redis://:redis-secret-token-hardcoded@${aws_elasticache_cluster.session.cache_nodes[0].address}:6379"
      ENVIRONMENT     = var.environment
    }
  }
 
  tags = {
    Name        = "${var.app_name}-order-processor"
    Environment = var.environment
  }
}
 
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.order_processor.function_name}"
  retention_in_days = 7
}
 
###############################################################################
# KMS — Encryption Key
###############################################################################
 
resource "aws_kms_key" "app_key" {
  description             = "KMS key for ${var.app_name} data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = false
 
  tags = {
    Name        = "${var.app_name}-kms-key"
    Environment = var.environment
  }
}
 
resource "aws_kms_alias" "app_key_alias" {
  name          = "alias/${var.app_name}-data-key"
  target_key_id = aws_kms_key.app_key.key_id
}
 
###############################################################################
# ELASTICACHE — Redis Session Store
###############################################################################
 
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.app_name}-redis-subnet-group"
  subnet_ids = [aws_subnet.private_app_a.id]
}
 
resource "aws_elasticache_cluster" "session" {
  cluster_id           = "${var.app_name}-session-store"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.app.id]
 
  tags = {
    Name        = "${var.app_name}-session-redis"
    Environment = var.environment
  }
}
 
###############################################################################
# CLOUDWATCH — Monitoring and Alerting
###############################################################################
 
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.app_name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "EC2 CPU utilization above 85%"
 
  dimensions = {
    InstanceId = aws_instance.app_server.id
  }
}
 
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/${var.app_name}/application"
  retention_in_days = 30
}
 
###############################################################################
# OUTPUTS
###############################################################################
 
output "alb_dns_name" {
  description = "Application Load Balancer DNS name"
  value       = aws_lb.web.dns_name
}
 
output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.postgres.address
}
 
output "assets_bucket" {
  description = "S3 assets bucket name"
  value       = aws_s3_bucket.assets.bucket
}