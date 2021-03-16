resource "aws_route53_zone" "cabal_control_zone" {
  name          = var.name
  comment       = "Control domain for cabal-mail infrastructure"
  force_destroy = true
  tags          = {
    Name                 = "cabal-control-zone"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "null_resource" "cabal_fixup_nameservers" {
  provisioner "local-exec" {
    command = "aws route53domains update-domain-nameservers --domain-name ${var.name} --nameservers Name=${aws_route53_zone.cabal_control_zone.name_servers[0]} Name=${aws_route53_zone.cabal_control_zone.name_servers.[1]} Name=${aws_route53_zone.cabal_control_zone.name_servers.[2]} Name=${aws_route53_zone.cabal_control_zone.name_servers.[3]}"
  }
}