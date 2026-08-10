import { describe, it, expect } from 'vitest';
import { hasRemoteContent, remoteContentBlockMeta, allowRemoteContent } from './remoteContent';

describe('hasRemoteContent', () => {
  it('detects a plain <img src> reference', () => {
    expect(hasRemoteContent('<img src="https://tracker.example.com/p.png">')).toBe(true);
  });

  it.each([
    ['inline background-image', '<div style="background-image:url(https://tracker.example.com/a.png)">x</div>'],
    ['<style> block', '<style>.hero { background-image: url("https://tracker.example.com/b.png"); }</style>'],
    ['srcset with no src', '<img srcset="https://tracker.example.com/c.png 1x">'],
    ['video poster', '<video poster="https://tracker.example.com/d.png"></video>'],
    ['@import', '<style>@import "https://tracker.example.com/e.css";</style>'],
    ['legacy background attribute', '<table background="https://tracker.example.com/f.png"></table>'],
    ['<input type=image>', '<input type="image" src="https://tracker.example.com/g.png">'],
    ['<object data>', '<object data="https://tracker.example.com/h.swf"></object>'],
    ['<link href>', '<link rel="stylesheet" href="https://tracker.example.com/i.css">'],
  ])('detects a remote reference via %s', (_label, html) => {
    expect(hasRemoteContent(html)).toBe(true);
  });

  it('ignores a hyperlink, which fetches nothing until clicked', () => {
    expect(hasRemoteContent('<p><a href="https://example.com/">click</a></p>')).toBe(false);
  });

  it('ignores cid: and data: references', () => {
    expect(hasRemoteContent('<img src="cid:part1@mail"><img src="data:image/png;base64,AA">')).toBe(false);
  });

  it('tolerates empty and missing HTML', () => {
    expect(hasRemoteContent('')).toBe(false);
    expect(hasRemoteContent(undefined)).toBe(false);
  });
});

describe('remoteContentBlockMeta', () => {
  it('denies everything by default and admits only local image sources', () => {
    const meta = remoteContentBlockMeta();
    expect(meta).toContain("default-src 'none'");
    expect(meta).toContain('img-src data: blob:');
    expect(meta).toContain("style-src 'unsafe-inline'");
    expect(meta).not.toMatch(/img-src[^;"]*https?:\/\//);
  });

  it('admits the origins of presigned inline-attachment URLs', () => {
    const meta = remoteContentBlockMeta([
      'https://cache.example.com/user/INBOX/1/img1?sig=abc',
      'https://cache.example.com/user/INBOX/1/img2?sig=def',
    ]);
    expect(meta).toContain('img-src data: blob: https://cache.example.com;');
    // One origin, not one entry per URL, and no query strings in the policy.
    expect(meta).not.toContain('sig=');
  });

  it('drops unresolved and non-http inline-image entries', () => {
    const meta = remoteContentBlockMeta([null, 'not a url', 'javascript:alert(1)']);
    expect(meta).toContain('img-src data: blob:;');
  });
});

describe('allowRemoteContent', () => {
  it('removes the blocking policy and leaves the rest of the document alone', () => {
    const doc = `<html><head>${remoteContentBlockMeta()}<style>body{}</style></head><body>hi</body></html>`;
    const allowed = allowRemoteContent(doc);
    expect(allowed).not.toContain('Content-Security-Policy');
    expect(allowed).toContain('<style>body{}</style>');
    expect(allowed).toContain('<body>hi</body>');
  });
});
