import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import ReaderBody from './ReaderBody';

const mockApi = {
  fetchImage: vi.fn().mockResolvedValue({ data: { url: 'https://cache.example.com/signed/img?sig=1' } }),
};

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

function renderBody(html) {
  return render(
    <ReaderBody
      format="rich"
      html={html}
      plain=""
      folder="INBOX"
      messageId={1}
      seen={true}
      setMessage={vi.fn()}
    />,
  );
}

const srcdoc = (container) => container.querySelector('iframe').getAttribute('srcdoc');

describe('ReaderBody remote-content blocking', () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('offers the opt-in control for a message whose only remote refs are in CSS', async () => {
    const { unmount } = renderBody(
      '<div style="background-image:url(https://tracker.example.com/a.png)">hi</div>'
      + '<style>.x { background-image: url("https://tracker.example.com/b.png"); }</style>',
    );
    try {
      await waitFor(() => {
        expect(screen.getByText('Remote images are blocked to protect your privacy.')).toBeInTheDocument();
      });
      expect(screen.getByRole('button', { name: 'Load images' })).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('blocks every remote subresource in the document it renders', async () => {
    const { container, unmount } = renderBody(
      '<html><head><title>t</title></head><body>'
      + '<img srcset="https://tracker.example.com/c.png 1x">'
      + '<video poster="https://tracker.example.com/d.png"></video>'
      + '</body></html>',
    );
    try {
      await waitFor(() => {
        expect(srcdoc(container)).toContain('Content-Security-Policy');
      });
      const doc = srcdoc(container);
      expect(doc).toContain("default-src 'none'");
      // The policy has to parse before the sender's first remote reference.
      expect(doc.indexOf('Content-Security-Policy')).toBeLessThan(doc.indexOf('srcset'));
      expect(doc.indexOf('<head>')).toBeLessThan(doc.indexOf('Content-Security-Policy'));
    } finally {
      unmount();
    }
  });

  it('admits presigned cid: attachment URLs while remote content is blocked', async () => {
    const { container, unmount } = renderBody('<img src="cid:part1@mail">');
    try {
      await waitFor(() => {
        expect(srcdoc(container)).toContain('https://cache.example.com/signed/img?sig=1');
      });
      expect(srcdoc(container)).toContain('img-src data: blob: https://cache.example.com;');
    } finally {
      unmount();
    }
  });

  it('drops the policy once the user loads images', async () => {
    const { container, unmount } = renderBody(
      '<div style="background-image:url(https://tracker.example.com/a.png)">hi</div>',
    );
    try {
      await waitFor(() => {
        expect(srcdoc(container)).toContain('Content-Security-Policy');
      });
      fireEvent.click(screen.getByRole('button', { name: 'Load images' }));
      await waitFor(() => {
        expect(srcdoc(container)).not.toContain('Content-Security-Policy');
      });
      expect(screen.queryByRole('button', { name: 'Load images' })).not.toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('leaves a message with no remote refs unbannered but still policed', async () => {
    const { container, unmount } = renderBody('<p>plain <a href="https://example.com/">link</a></p>');
    try {
      await waitFor(() => {
        expect(srcdoc(container)).toContain('plain');
      });
      expect(screen.queryByRole('button', { name: 'Load images' })).not.toBeInTheDocument();
      expect(srcdoc(container)).toContain("default-src 'none'");
    } finally {
      unmount();
    }
  });
});
