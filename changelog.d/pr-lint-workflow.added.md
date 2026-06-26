- A `Lint` workflow now runs the code linters on every pull request, so
  failures surface at review time instead of after merge. It mirrors the
  merge-time checks - Terraform (tflint, checkov, trivy on both stacks),
  Python (pylint), Swift (swiftlint) - and adds ESLint for the React admin
  app, each path-filtered to the areas a PR touches.
