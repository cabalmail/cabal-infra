- **Release-dashboard hold no longer tripped by issue mentions in prose.**
  The Promote gate's fix-claim scan allowed any 30 characters between the
  fix verb and the `#N` refs, so a docs-only PR describing an issue's
  lifecycle ("#1911 closed on 2026-10-17, with #2060 and #2061 filed from
  it") held promotion as if it carried an unretested fix for the issues it
  merely filed. The scan now requires the refs to follow the verb directly,
  allowing only filler words ("for", "issue", a colon) in between; bare
  mentions, dates, and parentheticals no longer count as claims.
