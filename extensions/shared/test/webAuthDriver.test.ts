import { describe, expect, it, vi } from 'vitest';
import { authRedirectUri, tabDriver, type TabsLike } from '../src/auth/webAuthDriver';

const REDIRECT = 'https://admin.cabal-mail.example/extension-auth';

function fakeTabs() {
  const created: string[] = [];
  const tabs: TabsLike = {
    create: vi.fn(async (props: { url: string }) => {
      created.push(props.url);
      return { id: 7 };
    }),
  };
  return { tabs, created };
}

describe('tabDriver', () => {
  it('reports the configured redirect URI', () => {
    expect(tabDriver(REDIRECT, fakeTabs().tabs).redirectUri()).toBe(REDIRECT);
  });

  it('opens the sign-in tab and hands completion off to the background', async () => {
    const f = fakeTabs();
    // null means "the redirect will arrive as a tabs.onUpdated event"; the
    // driver must not hold a promise open across the interactive leg.
    await expect(
      tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize'),
    ).resolves.toBeNull();
    expect(f.created).toEqual(['https://auth.example/authorize']);
  });

  it('rejects when a tab cannot be opened', async () => {
    const f = fakeTabs();
    (f.tabs.create as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('nope'));
    await expect(
      tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize'),
    ).rejects.toThrow('nope');
  });
});

describe('authRedirectUri', () => {
  it('is the admin origin page the background watches for', () => {
    expect(authRedirectUri('cabal-mail.example')).toBe(REDIRECT);
  });
});
