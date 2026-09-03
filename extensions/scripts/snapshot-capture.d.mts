// Types for scripts/snapshot-capture.mjs, so its suite in shared/test/ is
// type-checked like the rest of the workspace. The helpers themselves stay
// plain ESM: the snapshot tool runs from `node` with no build step.

export interface Navigation {
  status: number;
  title: string;
}

export interface NavigationDescription {
  challenged: boolean;
  refused: boolean;
  summary: string;
}

export function describeNavigation(nav: Navigation): NavigationDescription;

export function captureFailureMessage(
  context: Navigation & { selector: string; headed: boolean },
): string;

export function absolutizeCssUrls(css: string, baseHref: string): string;

export interface InlinedStylesheets {
  html: string;
  inlined: string[];
  skipped: Array<{ href: string; reason: string }>;
}

export function inlineStylesheets(html: string, cssByHref: Map<string, string>): InlinedStylesheets;
