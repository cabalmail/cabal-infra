import { useCallback, useEffect, useRef, useState } from 'react';
import useApi from '../hooks/useApi';
import { useAppMessage } from '../contexts/AppMessageContext';

function recordLabel(type) {
  return type === 'dkim' ? 'DKIM' : 'SPF';
}

function actualSummary(actual) {
  if (!actual) return '';
  if (actual.status === 'nxdomain') return 'No record published (NXDOMAIN).';
  if (actual.status === 'no_records' || !actual.values || actual.values.length === 0) {
    return 'No record published.';
  }
  return actual.values.join('\n');
}

function DnsCheckModal({ open, recordType, domain, onClose }) {
  const api = useApi();
  const { setMessage } = useAppMessage();
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);
  const [repairing, setRepairing] = useState(false);
  const closeRef = useRef(null);

  const fetchCheck = useCallback(() => {
    if (!domain || !recordType) return;
    setLoading(true);
    setResult(null);
    api.checkDnsRecord(domain, recordType).then(
      (response) => {
        const data = response.data || response;
        setResult(data);
        setLoading(false);
      },
      (err) => {
        setMessage('Failed to check DNS: ' + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [api, domain, recordType, setMessage]);

  useEffect(() => {
    if (open) fetchCheck();
  }, [open, fetchCheck]);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  useEffect(() => {
    if (open && closeRef.current) closeRef.current.focus();
  }, [open]);

  const onScrimMouseDown = useCallback((e) => {
    if (e.target === e.currentTarget) onClose();
  }, [onClose]);

  const repair = useCallback(() => {
    setRepairing(true);
    api.repairDnsRecord(domain, recordType).then(
      () => {
        setRepairing(false);
        setMessage(`${recordLabel(recordType)} record published. DNS may take a few minutes to propagate.`, false);
        fetchCheck();
      },
      (err) => {
        setRepairing(false);
        const detail = err?.response?.data?.Error || err.message || String(err);
        setMessage('Failed to publish record: ' + detail, true);
      }
    );
  }, [api, domain, recordType, fetchCheck, setMessage]);

  if (!open) return null;

  let body;
  if (loading) {
    body = <div className="dns-status">Checking DNS...</div>;
  } else if (!result) {
    body = <div className="dns-status">Unable to load check result.</div>;
  } else {
    let banner;
    if (result.matches) {
      banner = <div className="dns-banner ok">Published record matches the expected configuration.</div>;
    } else if (!result.managed) {
      banner = (
        <div className="dns-banner warn">
          {result.domain} is not managed by Cabal. The record cannot be repaired from here.
        </div>
      );
    } else if (result.is_apex) {
      banner = (
        <div className="dns-banner warn">
          {result.domain} is the apex of a managed mail domain. By design, the apex has no
          mail records; messages should be sent from a subdomain instead.
        </div>
      );
    } else {
      banner = (
        <div className="dns-banner err">
          The published record does not match what Cabal expects. Click Repair to publish
          the correct record in Route&nbsp;53.
        </div>
      );
    }

    body = (
      <>
        {banner}
        <section className="dns-section">
          <h4>Expected</h4>
          <dl className="dns-kv">
            <dt>Type</dt><dd>{result.expected.type}</dd>
            <dt>Name</dt><dd>{result.expected.name}</dd>
            <dt>Value</dt><dd className="dns-value">{result.expected.value}</dd>
          </dl>
        </section>
        <section className="dns-section">
          <h4>Currently published</h4>
          <pre className="dns-actual">{actualSummary(result.actual)}</pre>
        </section>
      </>
    );
  }

  const showRepair = result && result.repairable;

  return (
    <div className="source-scrim" onMouseDown={onScrimMouseDown} role="presentation">
      <div className="source-window dns-window" role="dialog" aria-modal="true" aria-label={`${recordLabel(recordType)} check`}>
        <div className="source-header">
          <div className="source-header-title">
            <span className="source-header-label">{recordLabel(recordType)} check</span>
            <span className="source-header-subject" title={domain}>{domain}</span>
          </div>
          <div className="source-header-tools">
            {showRepair && (
              <button
                type="button"
                className="source-tool dns-repair"
                onClick={repair}
                disabled={repairing}
              >
                {repairing ? 'Publishing...' : 'Repair'}
              </button>
            )}
            <button
              type="button"
              className="source-close"
              ref={closeRef}
              onClick={onClose}
              aria-label="Close check"
            >
              &#x2715;
            </button>
          </div>
        </div>
        <div className="source-body dns-body">{body}</div>
      </div>
    </div>
  );
}

export default DnsCheckModal;
