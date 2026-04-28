import React, { useCallback } from 'react';
import { Download } from 'lucide-react';

/* =========================================================================
   Attachments block — §4d. Extension badge (colored per family) + filename
   + size, with a download icon-button on the right.
   ========================================================================= */

const FAMILY_BY_EXT = {
  pdf: 'pdf',
  jpg: 'image', jpeg: 'image', png: 'image', gif: 'image',
  webp: 'image', bmp: 'image', svg: 'image', heic: 'image', tiff: 'image',
  zip: 'archive', tar: 'archive', gz: 'archive', tgz: 'archive',
  rar: 'archive', '7z': 'archive', bz2: 'archive',
  doc: 'doc', docx: 'doc', xls: 'doc', xlsx: 'doc',
  ppt: 'doc', pptx: 'doc', odt: 'doc', ods: 'doc', rtf: 'doc', txt: 'doc',
};

function extOf(name) {
  if (!name) return '';
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.slice(i + 1).toLowerCase() : '';
}

function familyFor(ext) {
  return FAMILY_BY_EXT[ext] || 'default';
}

function formatSize(bytes) {
  if (bytes == null || isNaN(bytes)) return '';
  const n = Number(bytes);
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function Attachments({ attachments, onDownload }) {
  const handleClick = useCallback((id) => (e) => {
    e.preventDefault();
    onDownload(id);
  }, [onDownload]);

  if (!attachments || attachments.length === 0) return null;

  return (
    <section className="reader-attachments" aria-labelledby="reader-attachments-heading">
      <h2 id="reader-attachments-heading" className="reader-attachments-heading">
        Attachments ({attachments.length})
      </h2>
      <ul className="reader-attachment-list">
        {attachments.map((a) => {
          const ext = extOf(a.name);
          const family = familyFor(ext);
          return (
            <li key={a.id} className="reader-attachment">
              <span
                className={`reader-attachment-badge family-${family}`}
                aria-hidden="true"
              >
                {(ext || '•').slice(0, 4)}
              </span>
              <span className="reader-attachment-meta">
                <span className="reader-attachment-name" title={a.name}>
                  {a.name}
                </span>
                <span className="reader-attachment-size">
                  {formatSize(a.size)}
                </span>
              </span>
              <button
                type="button"
                className="reader-attachment-download"
                onClick={handleClick(a.id)}
                title={`Download ${a.name}`}
                aria-label={`Download ${a.name}`}
              >
                <Download size={16} aria-hidden="true" />
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

export default Attachments;
