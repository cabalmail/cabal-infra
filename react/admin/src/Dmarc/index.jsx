import { useState, useCallback } from 'react';
import useApi from '../hooks/useApi';
import usePagedReports from '../hooks/usePagedReports';
import useSourceModal from '../hooks/useSourceModal';
import { useAppMessage } from '../contexts/AppMessageContext';
import XmlSourceModal from './XmlSourceModal';
import DnsCheckModal from './DnsCheckModal';
import './Dmarc.css';

function formatDate(epoch) {
  if (!epoch || epoch === '0') return '';
  const d = new Date(Number(epoch) * 1000);
  return d.toLocaleDateString();
}

function sortByDate(reports) {
  return [...reports].sort((a, b) => Number(b.date_end || 0) - Number(a.date_end || 0));
}

function arinUrl(ip) {
  return `https://search.arin.net/rdap/?query=${encodeURIComponent(ip)}`;
}

function xmlFilename(report) {
  const safe = (s) => (s || 'unknown').replace(/[^A-Za-z0-9._-]+/g, '_');
  return `${safe(report.org_name)}-${safe(report.report_id)}.xml`;
}

function ResultBadge({ value, onFailClick, label }) {
  if (!value) return <span className="result">-</span>;
  if (value === 'pass') return <span className="result pass">pass</span>;
  if (onFailClick) {
    return (
      <button
        type="button"
        className="result-fail"
        onClick={onFailClick}
        title={`Check ${label} configuration`}
      >
        fail
      </button>
    );
  }
  return <span className="result fail">{value}</span>;
}

function Dmarc() {
  const api = useApi();
  const { setMessage } = useAppMessage();

  const fetchPage = useCallback((token) => api.listDmarcReports(token), [api]);
  const { reports, loading, nextToken, refresh, loadMore } = usePagedReports({
    fetchPage,
    sortReports: sortByDate,
    errorLabel: 'DMARC',
  });

  const { show: showXml, close: closeXml, modalProps: xmlProps } = useSourceModal('dmarc-report.xml');

  const [dnsOpen, setDnsOpen] = useState(false);
  const [dnsType, setDnsType] = useState('dkim');
  const [dnsDomain, setDnsDomain] = useState('');

  const openXml = useCallback((report) => {
    if (!report.xml_url) {
      setMessage('No XML stored for this report.', true);
      return;
    }
    showXml({
      title: `${report.org_name || ''} - ${report.report_id || ''}`,
      filename: xmlFilename(report),
      load: () => api.fetchDmarcXml(report.xml_url),
    });
  }, [api, setMessage, showXml]);

  const openDns = useCallback((domain, recordType) => {
    if (!domain) return;
    setDnsDomain(domain);
    setDnsType(recordType);
    setDnsOpen(true);
  }, []);

  if (loading && reports.length === 0) {
    return <div className="Dmarc"><div className="loading">Loading...</div></div>;
  }

  return (
    <div className="Dmarc">
      <button id="reload" onClick={refresh}>&#x21bb;</button>

      <h2>DMARC Reports</h2>
      {reports.length === 0 ? (
        <p className="empty">No DMARC reports found.</p>
      ) : (
        <>
          <ul className="report-list">
            <li className="report-header">
              <span>Date Range</span>
              <span>Org</span>
              <span>Domain</span>
              <span>Source IP</span>
              <span>Count</span>
              <span>DKIM</span>
              <span>SPF</span>
              <span>Disposition</span>
            </li>
            {reports.map((r, i) => (
              <li key={`${r.report_id}-${r.source_ip}-${i}`} className="report-row">
                <span className="date">
                  {r.xml_url ? (
                    <button
                      type="button"
                      className="date-link"
                      onClick={() => openXml(r)}
                      title="View report XML"
                    >
                      {formatDate(r.date_begin)} &ndash; {formatDate(r.date_end)}
                    </button>
                  ) : (
                    <>{formatDate(r.date_begin)} &ndash; {formatDate(r.date_end)}</>
                  )}
                </span>
                <span className="org">{r.org_name}</span>
                <span className="domain">{r.header_from}</span>
                <span className="ip">
                  {r.source_ip ? (
                    <a
                      className="ip-link"
                      href={arinUrl(r.source_ip)}
                      target="_blank"
                      rel="noopener noreferrer"
                      title="Look up on ARIN"
                    >
                      {r.source_ip}
                    </a>
                  ) : ''}
                </span>
                <span className="count">{r.count}</span>
                <ResultBadge
                  value={r.dkim_result}
                  label="DKIM"
                  onFailClick={r.dkim_result === 'fail' && r.header_from
                    ? () => openDns(r.header_from, 'dkim')
                    : null}
                />
                <ResultBadge
                  value={r.spf_result}
                  label="SPF"
                  onFailClick={r.spf_result === 'fail' && r.header_from
                    ? () => openDns(r.header_from, 'spf')
                    : null}
                />
                <span className="disposition">{r.disposition}</span>
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

      <XmlSourceModal {...xmlProps} onClose={() => closeXml()} />
      <DnsCheckModal
        open={dnsOpen}
        recordType={dnsType}
        domain={dnsDomain}
        onClose={() => setDnsOpen(false)}
      />
    </div>
  );
}

export default Dmarc;
