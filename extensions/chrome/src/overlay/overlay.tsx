/**
 * The in-page overlay: suggest popover, adopt banner, submit-guard modal,
 * confirm-failed banner, ambiguous badge. Rendered into a Shadow DOM
 * attached to a host <div> at the end of document.body so host-page CSS
 * cannot leak in (and ours cannot leak out). Styles are inline apart from
 * theme.css, which is injected into the shadow root as a <style> because
 * an inline style attribute cannot carry a media query -- the tokens it
 * defines on :host are what the inline var() references below resolve to,
 * and what flips the whole overlay when the system switches to dark.
 */

import { render } from 'preact';
import { useEffect, useMemo, useState } from 'preact/hooks';
import { signal } from '@preact/signals';
import themeCss from '../theme.css?inline';
import type {
  OverlayPort,
  SuggestModel,
  SuggestOutcome,
} from '@cabalmail/extension-shared/content/controller';

type ActiveUi =
  | { kind: 'none' }
  | { kind: 'suggest'; anchor: HTMLElement; model: SuggestModel; resolve: (o: SuggestOutcome) => void }
  | { kind: 'adopt'; anchor: HTMLElement; address: string; resolve: (c: 'create' | 'dismiss') => void }
  | { kind: 'guard'; address: string; resolve: (c: 'create-and-submit' | 'submit-anyway' | 'cancel') => void }
  | { kind: 'confirm-failed'; anchor: HTMLElement; resolve: (c: 'retry' | 'submit-anyway' | 'cancel') => void };

const active = signal<ActiveUi>({ kind: 'none' });
const notice = signal<string | null>(null);

const font = {
  fontFamily: 'var(--cm-font)',
  fontSize: '14px',
  color: 'var(--cm-fg)',
} as const;

const card = {
  ...font,
  position: 'absolute',
  background: 'var(--cm-bg)',
  border: '1px solid var(--cm-border)',
  borderRadius: '8px',
  boxShadow: 'var(--cm-shadow)',
  padding: '12px',
  zIndex: '2147483647',
  maxWidth: '340px',
} as const;

const buttonStyle = {
  ...font,
  padding: '6px 12px',
  borderRadius: '6px',
  border: '1px solid var(--cm-control-border)',
  background: 'var(--cm-control-bg)',
  cursor: 'pointer',
} as const;

const primaryButton = {
  ...buttonStyle,
  background: 'var(--cm-accent)',
  borderColor: 'var(--cm-accent)',
  color: 'var(--cm-accent-fg)',
} as const;

function anchoredPosition(anchor: HTMLElement): { top: string; left: string } {
  const rect = anchor.getBoundingClientRect();
  return {
    top: `${rect.bottom + window.scrollY + 4}px`,
    left: `${rect.left + window.scrollX}px`,
  };
}

/** Re-render on scroll/resize so anchored UI tracks its field. */
function useAnchor(anchor: HTMLElement) {
  const [, bump] = useState(0);
  useEffect(() => {
    const onMove = () => bump((n) => n + 1);
    window.addEventListener('scroll', onMove, true);
    window.addEventListener('resize', onMove);
    return () => {
      window.removeEventListener('scroll', onMove, true);
      window.removeEventListener('resize', onMove);
    };
  }, [anchor]);
  return anchoredPosition(anchor);
}

function SuggestPopover(props: {
  anchor: HTMLElement;
  model: SuggestModel;
  resolve: (o: SuggestOutcome) => void;
}) {
  const { model } = props;
  const position = useAnchor(props.anchor);
  const [apex, setApex] = useState(model.apexDomains[0] ?? '');
  const [generated, setGenerated] = useState(() => model.generate(apex));
  const [comment, setComment] = useState(model.defaultComment);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const address = useMemo(
    () => `${generated.local}@${generated.subdomain}.${apex}`,
    [generated, apex],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') props.resolve({ kind: 'dismissed' });
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  const commit = async () => {
    setBusy(true);
    setError(null);
    try {
      const committed = await model.commit({
        local: generated.local,
        subdomain: generated.subdomain,
        apex,
        comment: comment.slice(0, 100),
      });
      props.resolve({ kind: 'used', address: committed });
    } catch (err) {
      setError(`Couldn't create the address: ${String(err)}`);
      setBusy(false);
    }
  };

  return (
    <div style={{ ...card, ...position }} role="dialog" aria-label="Use a new Cabalmail address">
      <div style={{ fontWeight: '600', marginBottom: '8px' }}>
        Use a new Cabalmail address
      </div>
      <div style={{ display: 'flex', gap: '8px', alignItems: 'center', marginBottom: '8px' }}>
        <code style={{ ...font, fontFamily: 'monospace', wordBreak: 'break-all' }}>{address}</code>
        <button
          style={buttonStyle}
          disabled={busy}
          onClick={() => setGenerated(model.generate(apex))}
        >
          Refresh
        </button>
      </div>
      {model.apexDomains.length > 1 && (
        <label style={{ display: 'block', marginBottom: '8px' }}>
          Apex domain{' '}
          <select
            style={font}
            value={apex}
            disabled={busy}
            onChange={(e) => setApex((e.target as HTMLSelectElement).value)}
          >
            {model.apexDomains.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>
        </label>
      )}
      <label style={{ display: 'block', marginBottom: '10px' }}>
        Optional label{' '}
        <input
          style={{ ...font, width: '100%', boxSizing: 'border-box' }}
          value={comment}
          maxLength={100}
          disabled={busy}
          onInput={(e) => setComment((e.target as HTMLInputElement).value)}
        />
      </label>
      {error && <div style={{ color: 'var(--cm-danger)', marginBottom: '8px' }}>{error}</div>}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '8px' }}>
        <button style={buttonStyle} disabled={busy} onClick={() => props.resolve({ kind: 'dismissed' })}>
          Cancel
        </button>
        <button style={primaryButton} disabled={busy} onClick={commit}>
          {busy ? 'Creating…' : error ? 'Retry' : 'Use this address'}
        </button>
      </div>
    </div>
  );
}

function AdoptBanner(props: {
  anchor: HTMLElement;
  address: string;
  resolve: (c: 'create' | 'dismiss') => void;
}) {
  const position = useAnchor(props.anchor);
  return (
    <div style={{ ...card, ...position }} role="dialog" aria-label="Create Cabalmail address">
      <div style={{ marginBottom: '8px' }}>
        You typed a Cabalmail address that doesn't exist yet. Create it before
        submitting?
      </div>
      <div style={{ display: 'flex', gap: '8px' }}>
        <button style={primaryButton} onClick={() => props.resolve('create')}>
          Yes, create it
        </button>
        <button style={buttonStyle} onClick={() => props.resolve('dismiss')}>
          No, leave as-is
        </button>
      </div>
    </div>
  );
}

function GuardModal(props: {
  address: string;
  resolve: (c: 'create-and-submit' | 'submit-anyway' | 'cancel') => void;
}) {
  return (
    <div
      style={{
        position: 'fixed',
        inset: '0',
        background: 'var(--cm-scrim)',
        zIndex: '2147483647',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
      role="alertdialog"
      aria-label="Address does not exist yet"
    >
      <div style={{ ...card, position: 'static', maxWidth: '380px' }}>
        <div style={{ fontWeight: '600', marginBottom: '8px' }}>Wait</div>
        <div style={{ marginBottom: '12px' }}>
          The address you entered (<code style={{ fontFamily: 'monospace' }}>{props.address}</code>)
          doesn't exist yet. If you submit now, this site won't be able to
          email you.
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
          <button style={primaryButton} onClick={() => props.resolve('create-and-submit')}>
            Create the address and submit
          </button>
          <button style={{ ...buttonStyle, opacity: '0.75' }} onClick={() => props.resolve('submit-anyway')}>
            Submit anyway
          </button>
          <button style={buttonStyle} onClick={() => props.resolve('cancel')}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

function ConfirmFailedBanner(props: {
  anchor: HTMLElement;
  resolve: (c: 'retry' | 'submit-anyway' | 'cancel') => void;
}) {
  const position = useAnchor(props.anchor);
  return (
    <div style={{ ...card, ...position }} role="alertdialog" aria-label="Address not finalized">
      <div style={{ marginBottom: '8px' }}>
        Couldn't finalize your Cabalmail address (it will be cleaned up
        automatically in 24h). Submit anyway?
      </div>
      <div style={{ display: 'flex', gap: '8px' }}>
        <button style={primaryButton} onClick={() => props.resolve('retry')}>
          Retry
        </button>
        <button style={buttonStyle} onClick={() => props.resolve('submit-anyway')}>
          Submit anyway
        </button>
        <button style={buttonStyle} onClick={() => props.resolve('cancel')}>
          Cancel
        </button>
      </div>
    </div>
  );
}

function OverlayRoot() {
  const ui = active.value;
  const note = notice.value;
  return (
    <div>
      {ui.kind === 'suggest' && <SuggestPopover {...ui} />}
      {ui.kind === 'adopt' && <AdoptBanner {...ui} />}
      {ui.kind === 'guard' && <GuardModal {...ui} />}
      {ui.kind === 'confirm-failed' && <ConfirmFailedBanner {...ui} />}
      {note && (
        <div style={{ ...card, position: 'fixed', bottom: '16px', right: '16px' }}>{note}</div>
      )}
    </div>
  );
}

export function createOverlay(): OverlayPort {
  const host = document.createElement('div');
  host.setAttribute('data-cabalmail-overlay', '');
  document.body.appendChild(host);
  const shadow = host.attachShadow({ mode: 'closed' });
  const themeStyle = document.createElement('style');
  themeStyle.textContent = themeCss;
  shadow.appendChild(themeStyle);
  const mount = document.createElement('div');
  shadow.appendChild(mount);
  render(<OverlayRoot />, mount);

  const settle = <T,>(ui: (resolve: (v: T) => void) => ActiveUi): Promise<T> =>
    new Promise<T>((outer) => {
      active.value = ui((value) => {
        active.value = { kind: 'none' };
        outer(value);
      });
    });

  return {
    showSuggestPopover: (anchor, model) =>
      settle((resolve) => ({ kind: 'suggest', anchor, model, resolve })),
    showAdoptBanner: (anchor, address) =>
      settle((resolve) => ({ kind: 'adopt', anchor, address, resolve })),
    showSubmitGuardModal: (address) =>
      settle((resolve) => ({ kind: 'guard', address, resolve })),
    showConfirmFailedBanner: (anchor) =>
      settle((resolve) => ({ kind: 'confirm-failed', anchor, resolve })),
    showAmbiguousBadge: (anchor, onOpen) => {
      // A small clickable mark at the field's right edge, in the field's own
      // coordinate space via absolute positioning over the page (Shadow DOM,
      // so no host-page layout impact).
      const badge = document.createElement('button');
      badge.textContent = '@';
      badge.title = 'Suggest a Cabalmail address';
      badge.setAttribute('aria-label', 'Suggest a Cabalmail address');
      Object.assign(badge.style, {
        position: 'absolute',
        width: '20px',
        height: '20px',
        lineHeight: '18px',
        borderRadius: '10px',
        border: '1px solid var(--cm-control-border)',
        background: 'var(--cm-bg)',
        color: 'var(--cm-accent-text)',
        cursor: 'pointer',
        fontSize: '12px',
        zIndex: '2147483647',
        padding: '0',
      });
      const place = () => {
        const rect = anchor.getBoundingClientRect();
        badge.style.top = `${rect.top + window.scrollY + (rect.height - 20) / 2}px`;
        badge.style.left = `${rect.right + window.scrollX - 26}px`;
      };
      place();
      badge.addEventListener('click', (e) => {
        e.preventDefault();
        onOpen();
      });
      window.addEventListener('scroll', place, true);
      window.addEventListener('resize', place);
      shadow.appendChild(badge);
    },
    showSubdomainReuseNotice: (_anchor, subdomain) => {
      notice.value =
        `Heads up: ${subdomain} already hosts another of your addresses, ` +
        `so mail to this subdomain can be correlated across them.`;
      setTimeout(() => {
        notice.value = null;
      }, 8000);
    },
    hideAdoptBanner: () => {
      if (active.value.kind === 'adopt') {
        active.value.resolve('dismiss');
        active.value = { kind: 'none' };
      }
    },
  };
}
