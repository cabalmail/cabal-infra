- **Operator name in the client configuration.** `/config.js` and
  `/config.json` now carry `operator_name`, filled from the
  `OPERATOR_NAME` GitHub variable through a new `operator_name`
  Terraform variable, so the native apps' sign-up screens can name the
  operator in their SMS consent text the way the webmail's does. Empty
  when the variable is unset.
