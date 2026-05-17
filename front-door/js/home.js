/* Cabalmail home page — supporting JS.
 *
 * Intentionally tiny:
 *   1. Stamp the current year into the footer copyright.
 *   2. Smooth-scroll same-page anchor links.
 *
 * No theme toggle — dark/light follows prefers-color-scheme only. */

(function () {
  'use strict';

  // 1. Year stamp ----------------------------------------------------------
  document.querySelectorAll('[data-year]').forEach(function (el) {
    el.textContent = String(new Date().getFullYear());
  });

  // 2. Smooth-scroll for same-page anchors --------------------------------
  // Respects prefers-reduced-motion (uses instant jump in that case).
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  document.addEventListener('click', function (e) {
    var link = e.target.closest && e.target.closest('a[href^="#"]');
    if (!link) return;
    var hash = link.getAttribute('href');
    if (!hash || hash === '#' || hash.length < 2) return;
    var target = document.getElementById(hash.slice(1));
    if (!target) return;
    e.preventDefault();
    target.scrollIntoView({
      behavior: reduceMotion ? 'auto' : 'smooth',
      block: 'start'
    });
    // Update URL hash without re-triggering scroll
    if (history.pushState) history.pushState(null, '', hash);
  });
})();
