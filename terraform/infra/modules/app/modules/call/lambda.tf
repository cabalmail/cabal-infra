module "cabal_python_lambda" {
  count          = var.type == "python" ? 1 : 0
  source         = "./modules/python_lambda"
  name           = var.name
  runtime        = var.runtime
  region         = var.region
  account        = var.account
  control_domain = var.control_domain
  relay_ips      = var.relay_ips
  domains        = var.domains
}

module "cabal_node_lambda" {
  count          = var.type == "node" ? 1 : 0
  source         = "./modules/node_lambda"
  name           = var.name
  runtime        = var.runtime
  region         = var.region
  account        = var.account
  control_domain = var.control_domain
  relay_ips      = var.relay_ips
  domains        = var.domains
}