import React from 'react';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import BimiAvatar from './BimiAvatar';
import { _resetBimiCache } from '../../utils/bimiCache';

beforeEach(() => {
  _resetBimiCache();
});

describe('BimiAvatar', () => {
  it('shows the sender initials when there is no logo', async () => {
    const getBimi = vi.fn().mockResolvedValue(null);
    render(<BimiAvatar from="Mary Miller <m@example.com>" getBimi={getBimi} />);
    expect(await screen.findByText('MM')).toBeInTheDocument();
  });

  it('renders the logo image once it resolves', async () => {
    const getBimi = vi.fn().mockResolvedValue('https://x/logo.png');
    const { container } = render(<BimiAvatar from="news@chewy.com" getBimi={getBimi} />);
    await waitFor(() => {
      const img = container.querySelector('img.envelope-avatar-logo');
      expect(img).toBeTruthy();
      expect(img.getAttribute('src')).toBe('https://x/logo.png');
    });
    expect(getBimi).toHaveBeenCalledWith('chewy.com');
  });

  it('falls back to initials when the image fails to load', async () => {
    const getBimi = vi.fn().mockResolvedValue('https://x/broken.png');
    const { container } = render(<BimiAvatar from="Bob <b@x.com>" getBimi={getBimi} />);
    const img = await waitFor(() => {
      const el = container.querySelector('img.envelope-avatar-logo');
      expect(el).toBeTruthy();
      return el;
    });
    fireEvent.error(img);
    await waitFor(() => {
      expect(container.querySelector('img.envelope-avatar-logo')).toBeNull();
      expect(container.querySelector('.envelope-avatar-initials').textContent).toBe('B');
    });
  });

  it('shows initials and never fetches without a getBimi resolver', () => {
    const { container } = render(<BimiAvatar from="a@b.com" />);
    expect(container.querySelector('.envelope-avatar-initials')).toBeTruthy();
    expect(container.querySelector('img.envelope-avatar-logo')).toBeNull();
  });
});
