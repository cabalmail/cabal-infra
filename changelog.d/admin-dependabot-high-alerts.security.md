- **Patched high-severity `react/admin` dependencies.** Bumped
  `linkify-it` to 5.0.2 (CVE-2026-59887, quadratic-complexity DoS in the
  `mailto:` validator), `js-yaml` to 4.3.0 (CVE-2026-59869, quadratic CPU
  consumption via YAML merge-key chains), and `brace-expansion` to 1.1.16
  (CVE-2026-13149, exponential-time brace expansion). The latter two are
  transitive dev-tooling dependencies with no production runtime impact.
