/* ============================================================
   Cabalmail Mail rules — RulesList, RuleEditor, TweaksPanel
   ============================================================ */

const { useState, useEffect, useRef, useMemo } = React;

/* ---------- Tiny toggle ------------------------------------- */
function Toggle({ on, onChange, big, title }) {
  return (
    <button
      className={`toggle ${on ? 'on' : ''} ${big ? 'big' : ''}`}
      onClick={(e) => { e.stopPropagation(); onChange(!on); }}
      role="switch"
      aria-checked={on}
      title={title}
    />
  );
}
window.Toggle = Toggle;

/* ============================================================
   RulesList — master pane
   ============================================================ */
function RulesList({
  rules, selectedId, onSelect, onReorder, onToggle,
  onAdd, orderingStyle,
}) {
  const [dragId, setDragId] = useState(null);
  const [dropTarget, setDropTarget] = useState(null); // {id, edge: 'above'|'below'}

  const onDragStart = (e, id) => {
    setDragId(id);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', id);
  };
  const onDragOver = (e, id) => {
    if (!dragId || dragId === id) return;
    e.preventDefault();
    const rect = e.currentTarget.getBoundingClientRect();
    const edge = (e.clientY - rect.top) < rect.height / 2 ? 'above' : 'below';
    setDropTarget({ id, edge });
  };
  const onDrop = (e, id) => {
    e.preventDefault();
    if (!dragId || dragId === id) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const edge = (e.clientY - rect.top) < rect.height / 2 ? 'above' : 'below';
    onReorder(dragId, id, edge);
    setDragId(null); setDropTarget(null);
  };
  const onDragEnd = () => { setDragId(null); setDropTarget(null); };

  const move = (idx, delta) => {
    const j = idx + delta;
    if (j < 0 || j >= rules.length) return;
    const a = rules[idx], b = rules[j];
    onReorder(a.id, b.id, delta < 0 ? 'above' : 'below');
  };

  const enabledCount = rules.filter(r => r.enabled).length;

  return (
    <aside className="rules-pane">
      <div className="rules-head">
        <div className="rules-head-title">Rules</div>
        <div className="rules-head-meta">{enabledCount}/{rules.length} active</div>
      </div>

      <ol className="rules-list">
        {rules.map((r, i) => {
          const isDropTarget = dropTarget && dropTarget.id === r.id && dragId && dragId !== r.id;
          const cls = [
            'rule-item',
            r.id === selectedId ? 'selected' : '',
            !r.enabled ? 'disabled' : '',
            dragId === r.id ? 'dragging' : '',
            isDropTarget && dropTarget.edge === 'above' ? 'drop-above' : '',
            isDropTarget && dropTarget.edge === 'below' ? 'drop-below' : '',
          ].filter(Boolean).join(' ');

          return (
            <li
              key={r.id}
              className={cls}
              onClick={() => onSelect(r.id)}
              draggable={orderingStyle === 'drag'}
              onDragStart={(e) => onDragStart(e, r.id)}
              onDragOver={(e) => onDragOver(e, r.id)}
              onDrop={(e) => onDrop(e, r.id)}
              onDragEnd={onDragEnd}
            >
              {orderingStyle === 'drag' && (
                <span className="rule-handle" onClick={(e) => e.stopPropagation()}
                      title="Drag to reorder">
                  <Icon name="drag" size={14} />
                </span>
              )}
              {orderingStyle === 'arrows' && (
                <span className="rule-arrows" onClick={(e) => e.stopPropagation()}>
                  <button disabled={i === 0} onClick={() => move(i, -1)} title="Move up">
                    <Icon name="chevronUp" size={11} />
                  </button>
                  <button disabled={i === rules.length - 1} onClick={() => move(i, 1)} title="Move down">
                    <Icon name="chevronDown" size={11} />
                  </button>
                </span>
              )}
              {orderingStyle === 'priority' && (
                <input
                  className="rule-priority"
                  type="number"
                  value={i + 1}
                  min={1} max={rules.length}
                  onClick={(e) => e.stopPropagation()}
                  onChange={(e) => {
                    const v = Math.max(1, Math.min(rules.length, parseInt(e.target.value || '1', 10)));
                    if (v === i + 1) return;
                    const target = rules[v - 1];
                    onReorder(r.id, target.id, v < i + 1 ? 'above' : 'below');
                  }}
                />
              )}

              <span className="rule-index">{i + 1}</span>
              <div className="rule-body">
                <div className="rule-name">{r.name || 'Untitled rule'}</div>
                <div className="rule-desc">{describeRule(r)}</div>
              </div>
              <Toggle on={r.enabled} onChange={(v) => onToggle(r.id, v)} title="Enable rule" />
            </li>
          );
        })}
      </ol>

      <div className="rules-list-foot">
        <button className="btn" onClick={onAdd}>
          <Icon name="plus" size={13} />
          <span>New rule</span>
        </button>
      </div>
    </aside>
  );
}
window.RulesList = RulesList;

/* ============================================================
   Conditions block — three UI styles
   ============================================================ */
function ConditionsRows({ conds, onChange }) {
  const add = () => onChange([...conds, { field: 'from', value: '' }]);
  const update = (i, patch) => onChange(conds.map((c, j) => j === i ? { ...c, ...patch } : c));
  const remove = (i) => onChange(conds.filter((_, j) => j !== i) || []);
  return (
    <div className="section-card">
      <div className="cond-list">
        {conds.length === 0 && (
          <div style={{ padding: '14px 16px', color: 'var(--ink-quiet)', fontFamily: 'var(--font-reader)', fontStyle: 'italic', fontSize: 13 }}>
            No conditions — this rule will match every incoming message.
          </div>
        )}
        {conds.map((c, i) => (
          <div key={i} className={`cond-row ${i === 0 ? 'first' : ''}`}>
            <select className="field-select wide" value={c.field} onChange={(e) => update(i, { field: e.target.value })}>
              {FIELDS.map(f => <option key={f.value} value={f.value}>{f.rowLabel}</option>)}
            </select>
            <input
              className="cond-input"
              value={c.value}
              onChange={(e) => update(i, { value: e.target.value })}
              placeholder={
                c.field === 'from' || c.field === 'to' || c.field === 'cc' || c.field === 'bcc'
                  ? 'name@example.com or substring' : 'substring to match'
              }
            />
            <button className="cond-remove" onClick={() => remove(i)} title="Remove condition">
              <Icon name="close" size={13} />
            </button>
          </div>
        ))}
        <button className="cond-add" onClick={add}>
          <Icon name="plus" size={12} />
          <span>{conds.length === 0 ? 'Add a condition' : 'AND another condition'}</span>
        </button>
      </div>
    </div>
  );
}

function ConditionsSentence({ conds, onChange }) {
  const add = () => onChange([...conds, { field: 'from', value: '' }]);
  const update = (i, patch) => onChange(conds.map((c, j) => j === i ? { ...c, ...patch } : c));
  const remove = (i) => onChange(conds.filter((_, j) => j !== i) || []);
  return (
    <div className="section-card">
      <div className="cond-sentence">
        {conds.length === 0 ? (
          <span style={{ color: 'var(--ink-quiet)', fontStyle: 'italic', fontFamily: 'var(--font-reader)' }}>
            Apply this rule to every incoming message.{' '}
          </span>
        ) : null}
        {conds.map((c, i) => (
          <span key={i} className="frag-line">
            <span className={`frag-kw ${i === 0 ? 'start' : ''}`}>{i === 0 ? 'If' : 'and'}</span>
            <select
              className="frag-field"
              value={c.field}
              onChange={(e) => update(i, { field: e.target.value })}
            >
              {FIELDS.map(f => <option key={f.value} value={f.value}>{f.label}</option>)}
            </select>
            <span className="frag-kw">contains</span>
            <input
              className="frag-input"
              value={c.value}
              onChange={(e) => update(i, { value: e.target.value })}
              placeholder="…"
              style={{ width: `${Math.max(8, c.value.length + 1)}ch` }}
            />
            <button className="frag-remove" onClick={() => remove(i)} title="Remove">
              <Icon name="close" size={11} />
            </button>
          </span>
        ))}
        <button className="sent-add" onClick={add}>
          <Icon name="plus" size={10} />
          <span>{conds.length === 0 ? 'add an IF clause' : 'and …'}</span>
        </button>
      </div>
    </div>
  );
}

function ConditionsStacked({ conds, onChange }) {
  // One field per row, multiple values per field become AND of multiple conditions.
  // For the stacked form we collapse — first matching condition per field is shown.
  const valueFor = (field) => {
    const c = conds.find(c => c.field === field);
    return c ? c.value : '';
  };
  const setField = (field, value) => {
    const idx = conds.findIndex(c => c.field === field);
    if (value === '' && idx >= 0) {
      onChange(conds.filter((_, j) => j !== idx));
    } else if (idx >= 0) {
      onChange(conds.map((c, j) => j === idx ? { ...c, value } : c));
    } else {
      onChange([...conds, { field, value }]);
    }
  };
  return (
    <div className="section-card">
      <div className="cond-stack">
        {FIELDS.map(f => {
          const v = valueFor(f.value);
          return (
            <div key={f.value} className={`field-row ${v ? 'has-value' : ''}`}>
              <span className="field-label">{f.label}</span>
              <input
                className="field-input"
                value={v}
                onChange={(e) => setField(f.value, e.target.value)}
                placeholder={f.value === 'body' ? 'phrase in the message body…' : 'contains…'}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}

/* ============================================================
   Actions block — three UI styles + auxiliary
   ============================================================ */
function ActionsSegmented({ rule, set }) {
  const { action } = rule;
  const tabs = [
    { id: 'move',    label: 'Move to',  icon: 'folder' },
    { id: 'copy',    label: 'Copy to',  icon: 'copy' },
    { id: 'archive', label: 'Archive',  icon: 'archive' },
    { id: 'delete',  label: 'Delete',   icon: 'trash' },
  ];
  return (
    <>
      <div className="actions-block-label">Destination · pick one</div>
      <div className="dest-segmented" role="tablist">
        {tabs.map(t => (
          <button key={t.id}
            className={action === t.id ? 'active' : ''}
            onClick={() => set({ action: t.id })}
          >
            <Icon name={t.icon} size={13} />
            <span>{t.label}</span>
          </button>
        ))}
      </div>
      {action === 'move' && (
        <div className="dest-target">
          <span className="arrow">→</span>
          <select value={rule.moveFolder || ''} onChange={(e) => set({ moveFolder: e.target.value })}>
            {FOLDERS.map(f => <option key={f} value={f}>{f}</option>)}
          </select>
        </div>
      )}
      {action === 'copy' && (
        <FolderChipsPicker
          values={rule.copyFolders}
          onChange={(v) => set({ copyFolders: v })}
        />
      )}
    </>
  );
}

function ActionsDropdown({ rule, set }) {
  // 'Then…' dropdown — single combined select with synthetic options
  return (
    <>
      <div className="actions-block-label">Then…</div>
      <div className="dest-dropdown">
        <span className="dd-prefix">then,</span>
        <select
          value={rule.action}
          onChange={(e) => set({ action: e.target.value })}
        >
          <option value="move">Move to folder…</option>
          <option value="copy">Copy to folder(s)…</option>
          <option value="archive">Archive</option>
          <option value="delete">Delete</option>
        </select>
      </div>
      {rule.action === 'move' && (
        <div className="dest-target">
          <span className="arrow">→</span>
          <select value={rule.moveFolder || ''} onChange={(e) => set({ moveFolder: e.target.value })}>
            {FOLDERS.map(f => <option key={f} value={f}>{f}</option>)}
          </select>
        </div>
      )}
      {rule.action === 'copy' && (
        <FolderChipsPicker
          values={rule.copyFolders}
          onChange={(v) => set({ copyFolders: v })}
        />
      )}
    </>
  );
}

function ActionsChecklist({ rule, set }) {
  const options = [
    { id: 'move',    label: 'Move to folder' },
    { id: 'copy',    label: 'Copy to folder(s)' },
    { id: 'archive', label: 'Archive' },
    { id: 'delete',  label: 'Delete' },
  ];
  return (
    <>
      <div className="actions-block-label">Destination · only one</div>
      <div className="dest-checklist">
        {options.map(o => (
          <button key={o.id}
            className={`check-row ${rule.action === o.id ? 'selected' : ''}`}
            onClick={() => set({ action: o.id })}
          >
            <span className="check-radio" />
            <span>{o.label}</span>
          </button>
        ))}
      </div>
      {rule.action === 'move' && (
        <div className="dest-target">
          <span className="arrow">→</span>
          <select value={rule.moveFolder || ''} onChange={(e) => set({ moveFolder: e.target.value })}>
            {FOLDERS.map(f => <option key={f} value={f}>{f}</option>)}
          </select>
        </div>
      )}
      {rule.action === 'copy' && (
        <FolderChipsPicker
          values={rule.copyFolders}
          onChange={(v) => set({ copyFolders: v })}
        />
      )}
    </>
  );
}

/* ---- Multi-folder picker (chips + add) -------------------- */
function FolderChipsPicker({ values, onChange }) {
  const [showAdd, setShowAdd] = useState(false);
  const remaining = FOLDERS.filter(f => !values.includes(f));
  return (
    <div className="dest-target">
      <span className="arrow">↳</span>
      <div className="folder-chips">
        {values.length === 0 && (
          <span style={{ color: 'var(--ink-quiet)', fontSize: 12, fontStyle: 'italic', fontFamily: 'var(--font-reader)' }}>
            Pick one or more folders…
          </span>
        )}
        {values.map(v => (
          <span key={v} className="folder-chip">
            <span>{v}</span>
            <button onClick={() => onChange(values.filter(x => x !== v))} title="Remove">
              <Icon name="close" size={10} />
            </button>
          </span>
        ))}
        {showAdd ? (
          <select
            autoFocus
            className="folder-chip-add"
            style={{ minWidth: 140 }}
            value=""
            onBlur={() => setShowAdd(false)}
            onChange={(e) => {
              if (e.target.value) onChange([...values, e.target.value]);
              setShowAdd(false);
            }}
          >
            <option value="">Add folder…</option>
            {remaining.map(f => <option key={f} value={f}>{f}</option>)}
          </select>
        ) : remaining.length > 0 && (
          <button className="folder-chip-add" onClick={() => setShowAdd(true)}>
            + add
          </button>
        )}
      </div>
    </div>
  );
}

/* ---- Auxiliary action toggles (Flag / Mark read / Forward) - */
function AuxiliaryActions({ rule, set }) {
  const items = [
    { id: 'flag',     label: 'Flag',          sub: 'star this message',   icon: 'star' },
    { id: 'markRead', label: 'Mark as read',  sub: 'no unread badge',     icon: 'markRead' },
    { id: 'forwardT', label: 'Forward',       sub: 'send a copy onwards', icon: 'forward' },
  ];
  return (
    <div className="aux-actions">
      {items.map(it => {
        const on = it.id === 'forwardT' ? rule.forward.length > 0 : rule[it.id];
        return (
          <button
            key={it.id}
            className={`aux-action ${on ? 'on' : ''}`}
            onClick={() => {
              if (it.id === 'forwardT') {
                if (rule.forward.length > 0) set({ forward: [] });
                else set({ forward: [''] });
              } else {
                set({ [it.id]: !rule[it.id] });
              }
            }}
          >
            <span className="aux-icon"><Icon name={it.icon} size={13} /></span>
            <span>
              <span className="aux-label">{it.label}</span>
              <span className="aux-sub">{it.sub}</span>
            </span>
          </button>
        );
      })}
    </div>
  );
}

/* ---- Forward addresses chips (with validation) ------------- */
function ForwardAddresses({ values, onChange }) {
  const [draft, setDraft] = useState('');
  const inputRef = useRef(null);

  const realValues = values.filter(v => v !== ''); // ignore the placeholder empty
  const commit = () => {
    const v = draft.trim();
    if (!v) return;
    onChange([...realValues, v]);
    setDraft('');
  };
  const removeAt = (i) => onChange(realValues.filter((_, j) => j !== i));

  const invalidCount = realValues.filter(v => !isValidEmail(v)).length;

  return (
    <div className="forward-block">
      <div className="forward-head">
        <div className={`forward-title ${invalidCount > 0 ? 'has-error' : ''}`}>
          Forward to {realValues.length > 0 && `· ${realValues.length}`}
        </div>
        <div style={{ fontSize: 11, color: 'var(--ink-quiet)', fontFamily: 'var(--font-mono)' }}>
          press Enter to add
        </div>
      </div>
      <div className="forward-chips" onClick={() => inputRef.current?.focus()}>
        {realValues.map((v, i) => {
          const ok = isValidEmail(v);
          return (
            <span key={i} className={`email-chip ${ok ? '' : 'invalid'}`} title={ok ? '' : 'Not a valid email address'}>
              <span>{v}</span>
              <button onClick={() => removeAt(i)} title="Remove">
                <Icon name="close" size={10} />
              </button>
            </span>
          );
        })}
        <input
          ref={inputRef}
          className="email-input"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ',' || e.key === ' ') {
              e.preventDefault();
              commit();
            } else if (e.key === 'Backspace' && !draft && realValues.length > 0) {
              removeAt(realValues.length - 1);
            }
          }}
          onBlur={commit}
          placeholder={realValues.length === 0 ? 'name@example.com' : 'add another…'}
        />
      </div>
      {invalidCount > 0 && (
        <div className="forward-error">
          {invalidCount === 1 ? '1 address is not valid' : `${invalidCount} addresses are not valid`}.
        </div>
      )}
    </div>
  );
}

/* ============================================================
   RuleEditor — detail pane
   ============================================================ */
function RuleEditor({
  rule, setRule, onDelete, onDuplicate, onBack,
  conditionStyle, actionStyle,
}) {
  const set = (patch) => setRule({ ...rule, ...patch });
  const Conditions =
    conditionStyle === 'sentence' ? ConditionsSentence
    : conditionStyle === 'stacked' ? ConditionsStacked
    : ConditionsRows;
  const Actions =
    actionStyle === 'dropdown' ? ActionsDropdown
    : actionStyle === 'checklist' ? ActionsChecklist
    : ActionsSegmented;

  const showForward = rule.forward.length > 0;
  const isDelete = rule.action === 'delete';

  return (
    <div className="editor-scroll">
      {onBack && (
        <button className="mobile-back" onClick={onBack}>
          <Icon name="chevronLeft" size={14} />
          <span>Rules</span>
        </button>
      )}
      <div className="editor-head">
        <div>
          <input
            className="rule-name-input"
            value={rule.name}
            onChange={(e) => set({ name: e.target.value })}
            placeholder="Name this rule…"
          />
          <div className="rule-id-tag">id: {rule.id}</div>
        </div>
        <div className="editor-head-actions">
          <span className={`enable-label ${rule.enabled ? 'on' : ''}`}>
            {rule.enabled ? 'Enabled' : 'Disabled'}
          </span>
          <Toggle big on={rule.enabled} onChange={(v) => set({ enabled: v })} title="Enable" />
        </div>
      </div>

      {/* CONDITIONS */}
      <section className="section">
        <div className="section-head">
          <div>
            <span className="section-num">01</span>
            <span className="section-title">When mail arrives that matches…</span>
          </div>
          <span className="section-hint">all conditions must match (AND)</span>
        </div>
        <Conditions conds={rule.conditions} onChange={(c) => set({ conditions: c })} />
      </section>

      {/* ACTIONS */}
      <section className="section">
        <div className="section-head">
          <div>
            <span className="section-num">02</span>
            <span className="section-title">…do this</span>
          </div>
          <span className="section-hint">one destination, plus any extras</span>
        </div>
        <div className="section-card actions-card">
          <Actions rule={rule} set={set} />
          <div className={`aux-section ${isDelete ? 'is-disabled' : ''}`} style={{ marginTop: 18 }}>
            <div className="actions-block-label">
              Also
              {isDelete && <span className="delete-note"> · delete is final, so these don&rsquo;t apply.</span>}
            </div>
            <AuxiliaryActions rule={rule} set={set} />
            {showForward && (
              <ForwardAddresses
                values={rule.forward}
                onChange={(v) => set({ forward: v })}
              />
            )}
          </div>
        </div>
      </section>

      {/* SPILLTHROUGH */}
      <section className={`section ${isDelete ? 'is-disabled' : ''}`} style={{ marginBottom: 0 }}>
        <div className="section-head">
          <div>
            <span className="section-num">03</span>
            <span className="section-title">After this rule runs…</span>
          </div>
        </div>
        <div className="spillthrough">
          <div className="st-info">
            <div className="st-label">Continue to the next rule</div>
            <div className="st-desc">
              If on, the next rule in order is also evaluated. If off, processing stops here — typical for{' '}
              <code>delete</code> and final-resting-place <code>move</code> rules.
            </div>
          </div>
          <Toggle big on={rule.continueToNext} onChange={(v) => set({ continueToNext: v })} title="Continue" />
        </div>
      </section>

      <div className="editor-foot">
        <button className="btn ghost" onClick={onDuplicate}>
          <Icon name="duplicate" size={13} />
          <span>Duplicate</span>
        </button>
        <button className="btn danger" onClick={onDelete}>
          <Icon name="trash" size={13} />
          <span>Delete rule</span>
        </button>
        <span className="spacer" />
        <span className="save-state">
          <span className="save-dot" />
          <span>Saved locally</span>
        </span>
      </div>
    </div>
  );
}
window.RuleEditor = RuleEditor;

/* ============================================================
   Empty state
   ============================================================ */
function EmptyState({ onCreateBlank, onUseTemplate }) {
  return (
    <div className="empty-state">
      <div className="empty-illust" aria-hidden="true">
        <div className="e-line"><span className="e-dot" /><span className="e-bar" /><span className="e-bar" style={{ maxWidth: 40 }} /></div>
        <div className="e-line"><span className="e-dot" style={{ background: 'var(--ink-quiet)' }} /><span className="e-bar acc" /></div>
        <div className="e-line"><span className="e-dot" style={{ background: 'transparent' }} /><span className="e-bar" /><span className="e-bar" /></div>
        <div className="e-line"><span className="e-dot" /><span className="e-bar" style={{ maxWidth: 60 }} /></div>
        <div className="e-arrow">→ Receipts</div>
      </div>

      <h2 className="empty-title">No rules yet.</h2>
      <p className="empty-sub">
        Rules run top-to-bottom on every new message. Use them to file
        receipts, quiet newsletters, flag mail from people you care about,
        or forward on-call alerts.
      </p>

      <div className="empty-templates">
        {TEMPLATES.map(t => (
          <button key={t.name} className="tmpl" onClick={() => onUseTemplate(t)}>
            <span className="tmpl-name">{t.name}</span>
            <span className="tmpl-desc" style={{ whiteSpace: 'pre-line' }}>{t.desc}</span>
          </button>
        ))}
      </div>

      <div className="empty-or"><span>or</span></div>

      <button className="btn primary" onClick={onCreateBlank}>
        <Icon name="plus" size={13} />
        <span>Start with a blank rule</span>
      </button>
    </div>
  );
}
window.EmptyState = EmptyState;

/* ============================================================
   Tweaks panel
   ============================================================ */
function TweaksPanel({ state, setState, onClose }) {
  const ACCENTS = ['ink','oxblood','forest','azure','amber','plum'];
  return (
    <div className="tweaks">
      <div className="tweaks-header">
        <span className="tweaks-title">Tweaks</span>
        <button className="tweaks-close" onClick={onClose} title="Close">
          <Icon name="close" size={12} />
        </button>
      </div>

      <div className="tweak-group">
        <label className="tweak-label">Theme</label>
        <div className="segment">
          {['light','dark','system'].map(t => (
            <button key={t}
              className={state.theme === t ? 'active' : ''}
              onClick={() => setState({ theme: t })}
            >{t}</button>
          ))}
        </div>
      </div>

      <div className="tweak-group">
        <label className="tweak-label">Accent</label>
        <div className="accent-grid">
          {ACCENTS.map(a => (
            <button key={a}
              className={`accent-swatch ${state.accent === a ? 'active' : ''}`}
              data-c={a}
              title={a}
              onClick={() => setState({ accent: a })}
            />
          ))}
        </div>
      </div>

      <div className="tweak-group">
        <label className="tweak-label">Density</label>
        <div className="segment">
          {['compact','comfortable'].map(d => (
            <button key={d}
              className={state.density === d ? 'active' : ''}
              onClick={() => setState({ density: d })}
            >{d}</button>
          ))}
        </div>
      </div>

      <div className="tweak-group">
        <label className="tweak-label">Conditions UI</label>
        <div className="segment">
          {[
            { id: 'rows',     label: 'Rows' },
            { id: 'sentence', label: 'Sentence' },
            { id: 'stacked',  label: 'Stacked' },
          ].map(o => (
            <button key={o.id}
              className={state.conditionStyle === o.id ? 'active' : ''}
              onClick={() => setState({ conditionStyle: o.id })}
            >{o.label}</button>
          ))}
        </div>
      </div>

      <div className="tweak-group">
        <label className="tweak-label">Actions UI</label>
        <div className="segment">
          {[
            { id: 'segmented', label: 'Segmented' },
            { id: 'dropdown',  label: 'Dropdown' },
            { id: 'checklist', label: 'Checklist' },
          ].map(o => (
            <button key={o.id}
              className={state.actionStyle === o.id ? 'active' : ''}
              onClick={() => setState({ actionStyle: o.id })}
            >{o.label}</button>
          ))}
        </div>
      </div>

      <div className="tweak-group" style={{ marginBottom: 0 }}>
        <label className="tweak-label">Ordering UI</label>
        <div className="segment">
          {[
            { id: 'drag',     label: 'Drag' },
            { id: 'arrows',   label: 'Arrows' },
            { id: 'priority', label: 'Priority' },
          ].map(o => (
            <button key={o.id}
              className={state.orderingStyle === o.id ? 'active' : ''}
              onClick={() => setState({ orderingStyle: o.id })}
            >{o.label}</button>
          ))}
        </div>
      </div>
    </div>
  );
}
window.TweaksPanel = TweaksPanel;
