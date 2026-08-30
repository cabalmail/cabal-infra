- **Safari sign-in driver lint break.** The tab-based auth driver declared
  its timeout handle with `let` and assigned it once, which fails the
  workspace's `prefer-const` rule and was reddening every `extensions`
  CI run. Behaviour is unchanged.
