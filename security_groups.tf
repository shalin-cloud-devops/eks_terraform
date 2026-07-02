resource "aws_security_group" "boutique_app_sg" {
  name        = "boutique_app_sg"
  description = "Security group for Boutique App"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTPS from Bastion host"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]

  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "boutique_app_sg"
    Environment = "dev"
  }
}

resource "aws_security_group" "bastion_sg" {
  name        = "bastion_sg"
  description = "Security group for the Bastion Host"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "bastion_sg"
    Environment = "dev"

  }

}
