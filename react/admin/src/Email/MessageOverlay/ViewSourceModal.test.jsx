import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import ViewSourceModal from './ViewSourceModal';

const RAW = [
  'From: Alice <a@example.com>',
  'Subject: Hello',
  'Date: Thu, 17 Apr 2025 12:00:00 +0000',
  '',
  'This is the body.',
  'Second line.',
].join('\r\n');

afterEach(() => {
  vi.restoreAllMocks();
});

describe('ViewSourceModal', () => {
  it('returns nothing when closed', () => {
    const { container } = render(
      <ViewSourceModal open={false} subject="x" rawText={RAW} onClose={vi.fn()} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders the header label, subject, and action buttons', () => {
    const { container } = render(
      <ViewSourceModal open subject="Hello subject" rawText={RAW} onClose={vi.fn()} />,
    );
    expect(screen.getByText('Message source')).toBeInTheDocument();
    expect(container.querySelector('.source-header-subject').textContent).toBe('Hello subject');
    expect(screen.getByRole('button', { name: 'Copy' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save .eml' })).toBeInTheDocument();
  });

  it('shows Full view with colorized header names and body', () => {
    const { container } = render(
      <ViewSourceModal open subject="Hello" rawText={RAW} onClose={vi.fn()} />,
    );
    const names = container.querySelectorAll('.hdr-name');
    const labels = Array.from(names).map((el) => el.textContent);
    expect(labels).toEqual(['From:', 'Subject:', 'Date:']);
    expect(container.textContent).toContain('This is the body.');
    expect(container.querySelector('.hdr-sep')).toBeInTheDocument();
  });

  it('Headers tab hides the body', () => {
    const { container } = render(
      <ViewSourceModal open subject="Hello" rawText={RAW} onClose={vi.fn()} />,
    );
    fireEvent.click(screen.getByRole('tab', { name: 'Headers' }));
    expect(container.textContent).not.toContain('This is the body.');
    expect(container.querySelectorAll('.hdr-name').length).toBe(3);
  });

  it('Body tab hides the headers', () => {
    const { container } = render(
      <ViewSourceModal open subject="Hello" rawText={RAW} onClose={vi.fn()} />,
    );
    fireEvent.click(screen.getByRole('tab', { name: 'Body' }));
    expect(container.querySelectorAll('.hdr-name').length).toBe(0);
    expect(container.textContent).toContain('This is the body.');
  });

  it('respects initialTab="headers" when opened from Show original headers', () => {
    const { container } = render(
      <ViewSourceModal
        open
        subject="Hello"
        rawText={RAW}
        onClose={vi.fn()}
        initialTab="headers"
      />,
    );
    expect(screen.getByRole('tab', { name: 'Headers' }).getAttribute('aria-selected')).toBe('true');
    expect(container.textContent).not.toContain('This is the body.');
  });

  it('Copy puts the raw text on the clipboard', async () => {
    const writeText = vi.fn().mockResolvedValue();
    Object.assign(navigator, { clipboard: { writeText } });
    render(
      <ViewSourceModal open subject="Hello" rawText={RAW} onClose={vi.fn()} />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'Copy' }));
    expect(writeText).toHaveBeenCalledWith(RAW);
  });

  it('Save .eml triggers an anchor download with message/rfc822 mime', () => {
    const createObjectURL = vi.fn().mockReturnValue('blob:mock');
    const revokeObjectURL = vi.fn();
    Object.assign(URL, { createObjectURL, revokeObjectURL });

    const blobs = [];
    const origBlob = global.Blob;
    global.Blob = function Blob(parts, opts) {
      blobs.push({ parts, opts });
      return new origBlob(parts, opts);
    };

    const clickSpy = vi
      .spyOn(HTMLAnchorElement.prototype, 'click')
      .mockImplementation(() => {});

    try {
      render(
        <ViewSourceModal open subject="Hello world" rawText={RAW} onClose={vi.fn()} />,
      );
      fireEvent.click(screen.getByRole('button', { name: 'Save .eml' }));
      expect(clickSpy).toHaveBeenCalled();
      expect(createObjectURL).toHaveBeenCalled();
      expect(blobs[0].opts.type).toBe('message/rfc822');
    } finally {
      clickSpy.mockRestore();
      global.Blob = origBlob;
    }
  });

  it('closes on Escape', () => {
    const onClose = vi.fn();
    render(
      <ViewSourceModal open subject="Hello" rawText={RAW} onClose={onClose} />,
    );
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });

  it('shows a loading state while raw source is still in flight', () => {
    render(
      <ViewSourceModal open subject="Hi" rawText="" loading onClose={vi.fn()} />,
    );
    expect(screen.getByText(/Loading source/i)).toBeInTheDocument();
  });

  it('shows an error state when raw source cannot be fetched', () => {
    render(
      <ViewSourceModal open subject="Hi" rawText="" error onClose={vi.fn()} />,
    );
    expect(screen.getByText(/Unable to load raw source/i)).toBeInTheDocument();
  });
});
