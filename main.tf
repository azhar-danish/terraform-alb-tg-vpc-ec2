#vpc
module "vpc" {
    source = "terraform-aws-modules/vpc/aws"

    name = "my-vpc"
    cidr = "10.0.0.0/16"

    azs             = ["us-east-1a", "us-east-1b"]
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
    public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

    enable_nat_gateway = true
    enable_vpn_gateway = true

    tags = {
        Terraform = "true"
        Environment = var.env
    }
}

#key pair
resource "aws_key_pair" "my-key-pair" {
    key_name = "node-app-keypair"
    public_key = file("keys/myapp.pub")
}

#security group
resource "aws_security_group" "ec2_SG" {
    name        = "ec2-SG"
    description = "Allow TLS inbound traffic and all outbound traffic"
    vpc_id      = module.vpc.vpc_id

    tags = {
        Name = "ec2-SG"
    }

    #inbound rules
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "SSH Open"
    }
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        security_groups = [aws_security_group.alb_sg.id]
        description     = "HTTP traffic restricted to ALB"
    }

    ingress {
        from_port = 8000
        to_port = 8000
        protocol = "tcp"
        security_groups = [aws_security_group.alb_sg.id] 
        description     = "Custom app traffic restricted to ALB"
    }

    #outbound rules

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        description = "All access open outbound"
    }
}

#ec2 instance
resource "aws_instance" "my_instance" {
    for_each = tomap({
        react-app-master = {
            type = "t2.small"
            ami_id = "ami-0b6d9d3d33ba97d99"
            subnet_id = module.vpc.public_subnets[0]
        }
        react-app-worker1 = {
            type = "t2.micro"
            ami_id = "ami-0b6d9d3d33ba97d99"
            subnet_id = module.vpc.public_subnets[1]
        }   
    })

    depends_on = [ module.vpc, aws_security_group.ec2_SG, aws_key_pair.my-key-pair ]
    key_name = aws_key_pair.my-key-pair.key_name
    
    vpc_security_group_ids = [aws_security_group.ec2_SG.id] 
    
    instance_type = each.value.type
    ami = each.value.ami_id
    subnet_id = each.value.subnet_id

    user_data = file("user_data/install-nginx.sh")
   
    associate_public_ip_address = true 
    root_block_device {
      volume_size = var.env == "dev" ? var.ec2_root_storage_size : 10
      volume_type = "gp2"
    }

    tags = {
        Name = each.key
        Environment = var.env
    }
}

#target-group
# 1. Create the Application Load Balancer Target Group
resource "aws_lb_target_group" "app_tg" {
  name        = "${var.env}-app-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id # Routes traffic within your custom VPC
  target_type = "instance"

  # Health check block tells the load balancer how to verify Nginx is running
  health_check {
    enabled             = true
    path                = "/"
    port                = "80"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "${var.env}-app-tg"
    Environment = var.env
  }
}

# 2. Attach your loop-generated EC2 instances to the Target Group
resource "aws_lb_target_group_attachment" "app_tg_attach" {
  for_each = aws_instance.my_instance # Loops through your existing master and worker instances

  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = each.value.id
  port             = 80
}


# 1. Create a Security Group for the ALB to allow public web traffic
resource "aws_security_group" "alb_sg" {
  name        = "${var.env}-alb-sg"
  description = "Allow public HTTP traffic to the Load Balancer"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Open to the public internet
    description = "Public HTTP Access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow ALB to talk to targets"
  }

  tags = {
    Name        = "${var.env}-alb-sg"
    Environment = var.env
  }
}

# 2. Define the Application Load Balancer
resource "aws_lb" "app_alb" {
  name               = "${var.env}-app-alb"
  internal           = false # Set to false so it gets a public DNS name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  
  # The ALB must be deployed across at least two public subnets in different AZs
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    Name        = "${var.env}-app-alb"
    Environment = var.env
  }
}

# 3. Create an HTTP Listener to forward incoming traffic to the Target Group
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn # Links to your target group
  }
}