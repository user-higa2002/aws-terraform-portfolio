resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "portfolio-vpc"
  }
}

resource "aws_subnet" "public_1a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "portfolio-public-subnet-1a"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "portfolio-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "portfolio-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_1a" {
  subnet_id      = aws_subnet.public_1a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web_sg" {
  name        = "portfolio-web-sg"
  description = "Security group for portfolio EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "portfolio-web-sg"
  }
}

resource "aws_instance" "web" {
  ami                    = "ami-0b53194d9d4d5cfea"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_1a.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  tags = {
    Name = "portfolio-terraform-web-01"
  }
}

resource "aws_iam_role" "ssm_role" {
  name = "portfolio-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "portfolio-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "portfolio-ssm-instance-profile"
  role = aws_iam_role.ssm_role.name
}

resource "aws_subnet" "public_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true

  tags = {
    Name = "portfolio-public-subnet-1c"
  }
}

resource "aws_route_table_association" "public_1c" {
  subnet_id      = aws_subnet.public_1c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb_sg" {
  name        = "portfolio-alb-sg"
  description = "Security group for portfolio ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "portfolio-alb-sg"
  }
}

resource "aws_lb" "main" {
  name               = "portfolio-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  subnets = [
    aws_subnet.public_1a.id,
    aws_subnet.public_1c.id
  ]

  tags = {
    Name = "portfolio-alb"
  }
}

resource "aws_lb_target_group" "web" {
  name     = "portfolio-tf-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "portfolio-tf-tg"
  }
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_launch_template" "web" {
  name_prefix   = "portfolio-web-"
  image_id      = "ami-0b53194d9d4d5cfea"
  instance_type = "t3.micro"
  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf install -y nginx
              systemctl enable nginx
              systemctl start nginx
              EOF
  )


  vpc_security_group_ids = [
    aws_security_group.web_sg.id
  ]

  iam_instance_profile {
    name = aws_iam_instance_profile.ssm_profile.name
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "portfolio-asg-web"
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name             = "portfolio-web-asg"
  desired_capacity = 2
  max_size         = 2
  min_size         = 2
  vpc_zone_identifier = [
    aws_subnet.public_1a.id,
    aws_subnet.public_1c.id
  ]

  target_group_arns = [
    aws_lb_target_group.web.arn
  ]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "portfolio-asg-web"
    propagate_at_launch = true
  }
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = "EC2-CPUUtilization-TF"
  alarm_description   = "EC2のCPU使用率が80%以上になった場合に通知するTerraform作成アラーム"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    InstanceId = aws_instance.web.id
  }

  alarm_actions = [
    "arn:aws:sns:ap-northeast-1:xxxxxxxxxxxx:Default_CloudWatch_Alarms_Topic"
  ]

  ok_actions = [
    "arn:aws:sns:ap-northeast-1:xxxxxxxxxxxx:Default_CloudWatch_Alarms_Topic"
  ]
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "EC2-StatusCheckFailed-TF"
  alarm_description   = "EC2のステータスチェック失敗を検知するTerraform作成アラーム"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1

  dimensions = {
    InstanceId = aws_instance.web.id
  }

  alarm_actions = [
    "arn:aws:sns:ap-northeast-1:384489631246:Default_CloudWatch_Alarms_Topic"
  ]

  ok_actions = [
    "arn:aws:sns:ap-northeast-1:384489631246:Default_CloudWatch_Alarms_Topic"
  ]
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host" {
  alarm_name          = "ALB-UnHealthyHostCount-TF"
  alarm_description   = "ALB配下の異常ターゲット数が1以上になった場合に通知するTerraform作成アラーム"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 1

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }

  alarm_actions = [
    "arn:aws:sns:ap-northeast-1:384489631246:Default_CloudWatch_Alarms_Topic"
  ]

  ok_actions = [
    "arn:aws:sns:ap-northeast-1:384489631246:Default_CloudWatch_Alarms_Topic"
  ]
}
