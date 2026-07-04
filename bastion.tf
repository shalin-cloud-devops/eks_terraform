resource "aws_iam_role" "bastion_ssm" {
  name = "bastion_ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_ssm_policy_role" {
  role       = aws_iam_role.bastion_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion-ssm-profile"
  role = aws_iam_role.bastion_ssm.name
}

module "bastion_host" {
  source        = "terraform-aws-modules/ec2-instance/aws"
  name          = "Bastion_Host"
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  monitoring    = true

  subnet_id                   = element(module.vpc.public_subnets, 0)
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.bastion_profile.name
}

