import { useState, useCallback } from 'react';

/**
 * Shared source-text modal state for the two report views (Dmarc, Caa).
 * Both hang an XmlSourceModal off a row link and fill it the same way: stamp
 * the header title and the download filename for the row that was clicked,
 * clear whatever the last row left behind, show the modal in its loading
 * state, then resolve one fetch into either the text or the error flag.
 *
 * Only the chrome is shared. The caller keeps the parts that differ per
 * report type: the guard for a report with nothing stored, how the title and
 * filename are built, and which API call fetches the source.
 *
 * `show` is referentially stable, so a caller may list it in a `useCallback`
 * dependency array without changing when that callback is rebuilt. `close` is
 * stable as well, which is why the views bind it through an inline arrow: the
 * modal's dismiss effect keys on `onClose`, and a fresh identity per render is
 * the churn it has always seen.
 *
 * @param {string} initialFilename Download name offered before any row has
 *   been opened; the modal never renders in that state, but the prop is read
 *   on the first render.
 * @returns {{show: Function, close: Function, modalProps: object}} `show`
 *   takes `{title, filename, load}` where `load()` returns the fetch promise;
 *   `modalProps` spreads onto XmlSourceModal (minus `onClose`).
 */
export default function useSourceModal(initialFilename) {
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [filename, setFilename] = useState(initialFilename);
  const [text, setText] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);

  const show = useCallback(({ title: nextTitle, filename: nextFilename, load }) => {
    setTitle(nextTitle);
    setFilename(nextFilename);
    setText('');
    setError(false);
    setLoading(true);
    setOpen(true);
    load().then(
      (r) => {
        setText(typeof r.data === 'string' ? r.data : String(r.data || ''));
        setLoading(false);
      },
      () => {
        setError(true);
        setLoading(false);
      }
    );
  }, []);

  const close = useCallback(() => setOpen(false), []);

  return {
    show,
    close,
    modalProps: { open, title, filename, xmlText: text, loading, error },
  };
}
