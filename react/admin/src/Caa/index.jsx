import { useCallback } from 'react';
import useApi from '../hooks/useApi';
import usePagedReports from '../hooks/usePagedReports';
import useSourceModal from '../hooks/useSourceModal';
import { useAppMessage } from '../contexts/AppMessageContext';
import XmlSourceModal from '../Dmarc/XmlSourceModal';
// Dmarc.css carries the shared modal scaffold (.source-*) that
// XmlSourceModal styles against; the CAA list grid lives in Caa.css.
import '../Dmarc/Dmarc.css';
import './Caa.css';

function formatDateTime(epoch) {
  if (!epoch || epoch === '0') return '';
  const d = new Date(Number(epoch) * 1000);
  return d.toLocaleString();
}

function sortByReceived(reports) {
  return [...reports].sort((a, b) => Number(b.received || 0) - Number(a.received || 0));
}

function rawFilename(report) {
  const safe = (s) => (s || 'unknown').replace(/[^A-Za-z0-9._-]+/g, '_');
  return `caa-report-${safe(report.from_domain)}-${safe(report.received)}.eml`;
}

function Caa() {
  const api = useApi();
  const { setMessage } = useAppMessage();

  const fetchPage = useCallback((token) => api.listCaaReports(token), [api]);
  const { reports, loading, nextToken, refresh, loadMore } = usePagedReports({
    fetchPage,
    sortReports: sortByReceived,
    errorLabel: 'CAA',
  });

  const { show: showRaw, close: closeRaw, modalProps: rawProps } = useSourceModal('caa-report.eml');

  const openRaw = useCallback((report) => {
    if (!report.raw_url) {
      setMessage('No raw message stored for this report.', true);
      return;
    }
    showRaw({
      title: `${report.from_addr || ''} - ${report.subject || ''}`,
      filename: rawFilename(report),
      load: () => api.fetchCaaReport(report.raw_url),
    });
  }, [api, setMessage, showRaw]);

  if (loading && reports.length === 0) {
    return <div className="Caa"><div className="loading">Loading...</div></div>;
  }

  return (
    <div className="Caa">
      <button id="reload" onClick={refresh}>&#x21bb;</button>

      <h2>CAA Violation Reports</h2>
      {reports.length === 0 ? (
        <p className="empty">
          No CAA violation reports. That is the expected state: a certificate
          authority sends one only when it refuses a certificate request that
          violates this system&apos;s CAA policy. Any report that appears here
          is a mis-issuance attempt (or a deliberate test) worth investigating.
        </p>
      ) : (
        <>
          <ul className="caa-list">
            <li className="caa-header">
              <span>Received</span>
              <span>From</span>
              <span>Domain</span>
              <span>Subject</span>
            </li>
            {reports.map((r, i) => (
              <li key={`${r.message_id}-${r.received}-${i}`} className="caa-row">
                <span className="date">
                  {r.raw_url ? (
                    <button
                      type="button"
                      className="date-link"
                      onClick={() => openRaw(r)}
                      title="View raw message"
                    >
                      {formatDateTime(r.received)}
                    </button>
                  ) : (
                    <>{formatDateTime(r.received)}</>
                  )}
                </span>
                <span className="from" title={r.from_addr}>{r.from_addr}</span>
                <span className="domain">{r.from_domain}</span>
                <span className="subject" title={r.subject}>{r.subject}</span>
              </li>
            ))}
          </ul>
          {nextToken && (
            <button className="load-more" onClick={loadMore} disabled={loading}>
              {loading ? 'Loading...' : 'Load more'}
            </button>
          )}
        </>
      )}

      <XmlSourceModal {...rawProps} onClose={() => closeRaw()} />
    </div>
  );
}

export default Caa;
