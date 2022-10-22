module "cabal_lambda" {
  source         = var.type == "python" ? "./modules/python_lambda" : "./modules/node_lambda"
  name           = var.name
  runtime        = var.runtime
  region         = var.region
  account        = var.account
  control_domain = var.control_domain
  relay_ips      = var.relay_ips
  domains        = var.domains
}