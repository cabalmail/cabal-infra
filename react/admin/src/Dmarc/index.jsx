import { useState, useEffect, useCallback } from 'react';
import useApi from '../hooks/useApi';
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
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [nextToken, setNextToken] = useState(null);

  const [xmlOpen, setXmlOpen] = useState(false);
  const [xmlTitle, setXmlTitle] = useState('');
  const [xmlFile, setXmlFile] = useState('dmarc-report.xml');
  const [xmlText, setXmlText] = useState('');
  const [xmlLoading, setXmlLoading] = useState(false);
  const [xmlError, setXmlError] = useState(false);

  const [dnsOpen, setDnsOpen] = useState(false);
  const [dnsType, setDnsType] = useState('dkim');
  const [dnsDomain, setDnsDomain] = useState('');

  const loadReports = useCallback((token) => {
    setLoading(true);
    api.listDmarcReports(token).then(
      (response) => {
        const data = response.data || response;
        const newReports = data.Reports || [];
        if (token) {
          setReports(prev => sortByDate([...prev, ...newReports]));
        } else {
          setReports(sortByDate(newReports));
        }
        setNextToken(data.NextToken || null);
        setLoading(false);
      },
      (err) => {
        setMessage("Failed to load DMARC reports: " + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [api, setMessage]);

  useEffect(() => {
    loadReports();
  }, [loadReports]);

  const handleRefresh = useCallback(() => {
    setNextToken(null);
    loadReports();
  }, [loadReports]);

  const handleLoadMore = useCallback(() => {
    if (nextToken) {
      loadReports(nextToken);
    }
  }, [nextToken, loadReports]);

  const openXml = useCallback((report) => {
    if (!report.xml_url) {
      setMessage('No XML stored for this report.', true);
      return;
    }
    setXmlTitle(`${report.org_name || ''} - ${report.report_id || ''}`);
    setXmlFile(xmlFilename(report));
    setXmlText('');
    setXmlError(false);
    setXmlLoading(true);
    setXmlOpen(true);
    api.fetchDmarcXml(report.xml_url).then(
      (r) => {
        setXmlText(typeof r.data === 'string' ? r.data : String(r.data || ''));
        setXmlLoading(false);
      },
      () => {
        setXmlError(true);
        setXmlLoading(false);
      }
    );
  }, [api, setMessage]);

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
      <button id="reload" onClick={handleRefresh}>&#x21bb;</button>

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
            <button className="load-more" onClick={handleLoadMore} disabled={loading}>
              {loading ? 'Loading...' : 'Load more'}
            </button>
          )}
        </>
      )}

      <XmlSourceModal
        open={xmlOpen}
        title={xmlTitle}
        filename={xmlFile}
        xmlText={xmlText}
        loading={xmlLoading}
        error={xmlError}
        onClose={() => setXmlOpen(false)}
      />
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
