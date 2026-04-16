import { useState, useEffect, useCallback } from 'react';
import useApi from '../hooks/useApi';
import { useAppMessage } from '../contexts/AppMessageContext';
import './Dmarc.css';

function formatDate(epoch) {
  if (!epoch || epoch === '0') return '';
  const d = new Date(Number(epoch) * 1000);
  return d.toLocaleDateString();
}

function sortByDate(reports) {
  return [...reports].sort((a, b) => Number(b.date_end || 0) - Number(a.date_end || 0));
}

function ResultBadge({ value }) {
  if (!value) return <span className="result">-</span>;
  const cls = value === 'pass' ? 'pass' : 'fail';
  return <span className={`result ${cls}`}>{value}</span>;
}

function Dmarc() {
  const api = useApi();
  const { setMessage } = useAppMessage();
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [nextToken, setNextToken] = useState(null);

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
                <span className="date">{formatDate(r.date_begin)} &ndash; {formatDate(r.date_end)}</span>
                <span className="org">{r.org_name}</span>
                <span className="domain">{r.header_from}</span>
                <span className="ip">{r.source_ip}</span>
                <span className="count">{r.count}</span>
                <ResultBadge value={r.dkim_result} />
                <ResultBadge value={r.spf_result} />
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
    </div>
  );
}

export default Dmarc;
