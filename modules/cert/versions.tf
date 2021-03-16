terraform {
  required_providers {
    acme = {
      source = "vancluever/acme"
      version = "2.2.0"
    }
  }

  required_version = ">= 0.14.0"
}
