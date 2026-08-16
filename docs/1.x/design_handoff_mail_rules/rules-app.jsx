/* ============================================================
   Cabalmail Mail rules — Root App + Topbar + UserMenu
   ============================================================ */

const { useState: useAS, useEffect: useAE, useRef: useAR } = React;

const LS_KEY = 'cabalmail-rules-tweaks';
const RULES_LS_KEY = 'cabalmail-rules-data';

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "light",
  "accent": "forest",
  "density": "comfortable",
  "conditionStyle": "rows",
  "actionStyle": "segmented",
  "orderingStyle": "drag"
}/*EDITMODE-END*/;

function loadTweaks() {
  try {
    const s = JSON.parse(localStorage.getItem(LS_KEY));
    return { ...TWEAK_DEFAULTS, ...(s || {}) };
  } catch { return { ...TWEAK_DEFAULTS }; }
}

function loadRules() {
  try {
    const raw = localStorage.getItem(RULES_LS_KEY);
    if (!raw) return SEED_RULES.map(r => ({ ...r }));
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed;
    return SEED_RULES.map(r => ({ ...r }));
  } catch { return SEED_RULES.map(r => ({ ...r })); }
}
function saveRules(rules) {
  try { localStorage.setItem(RULES_LS_KEY, JSON.stringify(rules)); } catch {}
}

const LOGO_PATH_D = "M0 0h45v1h-45zM54 0h146v1h-146zM0 1h38v1h-38zM60 1h19v1h-19zM80 1h116v1h-116zM197 1h3v1h-3zM0 2h35v1h-35zM64 2h15v1h-15zM82 2h113v1h-113zM197 2h3v1h-3zM0 3h32v1h-32zM67 3h12v1h-12zM83 3h111v1h-111zM197 3h3v1h-3zM0 4h29v1h-29zM69 4h10v1h-10zM84 4h108v1h-108zM197 4h3v1h-3zM0 5h27v1h-27zM71 5h8v1h-8zM85 5h106v1h-106zM197 5h3v1h-3zM0 6h25v1h-25zM73 6h6v1h-6zM87 6h103v1h-103zM197 6h3v1h-3zM0 7h24v1h-24zM75 7h4v1h-4zM88 7h101v1h-101zM197 7h3v1h-3zM0 8h22v1h-22zM77 8h2v1h-2zM89 8h99v1h-99zM197 8h3v1h-3zM0 9h21v1h-21zM78 9h1v1h-1zM90 9h96v1h-96zM197 9h3v1h-3zM0 10h19v1h-19zM92 10h93v1h-93zM197 10h3v1h-3zM0 11h18v1h-18zM93 11h91v1h-91zM197 11h3v1h-3zM0 12h17v1h-17zM94 12h89v1h-89zM197 12h3v1h-3zM0 13h16v1h-16zM95 13h86v1h-86zM197 13h3v1h-3zM0 14h15v1h-15zM96 14h84v1h-84zM197 14h3v1h-3zM0 15h14v1h-14zM98 15h81v1h-81zM197 15h3v1h-3zM0 16h13v1h-13zM99 16h79v1h-79zM197 16h3v1h-3zM0 17h12v1h-12zM100 17h76v1h-76zM197 17h3v1h-3zM0 18h11v1h-11zM55 18h2v1h-2zM101 18h74v1h-74zM197 18h3v1h-3zM0 19h10v1h-10zM54 19h3v1h-3zM103 19h71v1h-71zM197 19h3v1h-3zM0 20h10v1h-10zM53 20h4v1h-4zM104 20h69v1h-69zM197 20h3v1h-3zM0 21h9v1h-9zM52 21h5v1h-5zM105 21h67v1h-67zM197 21h3v1h-3zM0 22h8v1h-8zM50 22h7v1h-7zM106 22h64v1h-64zM197 22h3v1h-3zM0 23h8v1h-8zM49 23h8v1h-8zM108 23h61v1h-61zM197 23h3v1h-3zM0 24h7v1h-7zM48 24h9v1h-9zM109 24h59v1h-59zM197 24h3v1h-3zM0 25h6v1h-6zM47 25h10v1h-10zM110 25h57v1h-57zM197 25h3v1h-3zM0 26h6v1h-6zM46 26h11v1h-11zM111 26h54v1h-54zM197 26h3v1h-3zM0 27h5v1h-5zM45 27h12v1h-12zM112 27h52v1h-52zM197 27h3v1h-3zM0 28h5v1h-5zM43 28h14v1h-14zM114 28h49v1h-49zM197 28h3v1h-3zM0 29h4v1h-4zM42 29h15v1h-15zM115 29h47v1h-47zM197 29h3v1h-3zM0 30h4v1h-4zM41 30h16v1h-16zM116 30h44v1h-44zM197 30h3v1h-3zM0 31h4v1h-4zM40 31h17v1h-17zM117 31h42v1h-42zM197 31h3v1h-3zM0 32h3v1h-3zM39 32h40v1h-40zM119 32h39v1h-39zM197 32h3v1h-3zM0 33h3v1h-3zM38 33h41v1h-41zM120 33h37v1h-37zM197 33h3v1h-3zM0 34h2v1h-2zM36 34h43v1h-43zM121 34h35v1h-35zM197 34h3v1h-3zM0 35h2v1h-2zM35 35h44v1h-44zM122 35h32v1h-32zM197 35h3v1h-3zM0 36h2v1h-2zM34 36h45v1h-45zM124 36h29v1h-29zM197 36h3v1h-3zM0 37h2v1h-2zM33 37h46v1h-46zM125 37h27v1h-27zM197 37h3v1h-3zM0 38h1v1h-1zM32 38h47v1h-47zM126 38h25v1h-25zM197 38h3v1h-3zM0 39h1v1h-1zM31 39h48v1h-48zM127 39h22v1h-22zM197 39h3v1h-3zM0 40h1v1h-1zM29 40h50v1h-50zM128 40h20v1h-20zM197 40h3v1h-3zM0 41h1v1h-1zM28 41h51v1h-51zM130 41h17v1h-17zM197 41h3v1h-3zM0 42h1v1h-1zM27 42h52v1h-52zM131 42h15v1h-15zM197 42h3v1h-3zM0 43h1v1h-1zM26 43h53v1h-53zM132 43h12v1h-12zM197 43h3v1h-3zM25 44h54v1h-54zM133 44h10v1h-10zM197 44h3v1h-3zM24 45h55v1h-55zM135 45h7v1h-7zM197 45h3v1h-3zM23 46h56v1h-56zM136 46h5v1h-5zM197 46h3v1h-3zM21 47h58v1h-58zM137 47h3v1h-3zM197 47h3v1h-3zM20 48h59v1h-59zM197 48h3v1h-3zM19 49h60v2h-60zM197 49h3v2h-3zM20 51h59v1h-59zM197 51h3v1h-3zM21 52h58v1h-58zM197 52h3v1h-3zM23 53h56v1h-56zM197 53h3v1h-3zM24 54h55v1h-55zM197 54h3v1h-3zM0 55h1v1h-1zM25 55h54v1h-54zM197 55h3v1h-3zM0 56h1v1h-1zM26 56h53v1h-53zM197 56h3v1h-3zM0 57h1v1h-1zM27 57h52v1h-52zM197 57h3v1h-3zM0 58h1v1h-1zM28 58h51v1h-51zM197 58h3v1h-3zM0 59h1v1h-1zM30 59h49v1h-49zM197 59h3v1h-3zM0 60h1v1h-1zM31 60h48v1h-48zM197 60h3v1h-3zM0 61h2v1h-2zM32 61h47v1h-47zM197 61h3v1h-3zM0 62h2v1h-2zM33 62h46v1h-46zM197 62h3v1h-3zM0 63h2v1h-2zM34 63h45v1h-45zM197 63h3v1h-3zM0 64h3v1h-3zM35 64h44v1h-44zM197 64h3v1h-3zM0 65h3v1h-3zM36 65h43v1h-43zM197 65h3v1h-3zM0 66h3v1h-3zM38 66h41v1h-41zM197 66h3v1h-3zM0 67h4v1h-4zM39 67h40v1h-40zM197 67h3v1h-3zM0 68h4v1h-4zM40 68h17v1h-17zM197 68h3v1h-3zM0 69h5v1h-5zM41 69h16v1h-16zM197 69h3v1h-3zM0 70h5v1h-5zM42 70h15v1h-15zM197 70h3v1h-3zM0 71h6v1h-6zM43 71h14v1h-14zM197 71h3v1h-3zM0 72h6v1h-6zM45 72h12v1h-12zM197 72h3v1h-3zM0 73h7v1h-7zM46 73h11v1h-11zM197 73h3v1h-3zM0 74h7v1h-7zM47 74h10v1h-10zM197 74h3v1h-3zM0 75h8v1h-8zM48 75h9v1h-9zM197 75h3v1h-3zM0 76h8v1h-8zM49 76h8v1h-8zM197 76h3v1h-3zM0 77h9v1h-9zM50 77h7v1h-7zM197 77h3v1h-3zM0 78h10v1h-10zM52 78h5v1h-5zM197 78h3v1h-3zM0 79h11v1h-11zM53 79h4v1h-4zM197 79h3v1h-3zM0 80h11v1h-11zM54 80h3v1h-3zM197 80h3v1h-3zM0 81h12v1h-12zM55 81h2v1h-2zM197 81h3v1h-3zM0 82h13v1h-13zM197 82h3v1h-3zM0 83h14v1h-14zM197 83h3v1h-3zM0 84h15v1h-15zM197 84h3v1h-3zM0 85h16v1h-16zM197 85h3v1h-3zM0 86h17v1h-17zM197 86h3v1h-3zM0 87h18v1h-18zM197 87h3v1h-3zM0 88h20v1h-20zM197 88h3v1h-3zM0 89h21v1h-21zM78 89h1v1h-1zM197 89h3v1h-3zM0 90h23v1h-23zM76 90h3v1h-3zM197 90h3v1h-3zM0 91h24v1h-24zM75 91h4v1h-4zM197 91h3v1h-3zM0 92h26v1h-26zM73 92h6v1h-6zM197 92h3v1h-3zM0 93h28v1h-28zM71 93h8v1h-8zM197 93h3v1h-3zM0 94h30v1h-30zM69 94h10v1h-10zM197 94h3v1h-3zM0 95h32v1h-32zM66 95h13v1h-13zM197 95h3v1h-3zM0 96h35v1h-35zM63 96h16v1h-16zM197 96h3v1h-3zM0 97h40v1h-40zM59 97h20v1h-20zM197 97h3v1h-3zM0 98h200v2h-200z";

const USER_ACCENTS = ['ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'];

function HelpMenu() {
  const [open, setOpen] = useAS(false);
  const ref = useAR(null);
  useAE(() => {
    if (!open) return;
    const onDoc = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);
  return (
    <div className="help-menu-wrap" ref={ref}>
      <button
        className="help-trigger"
        onClick={() => setOpen(o => !o)}
        title="About mail rules"
        aria-label="About mail rules"
      >
        <Icon name="help" size={16} />
      </button>
      {open && (
        <div className="help-menu" role="dialog">
          <div className="help-eyebrow">How rules work</div>
          <h3 className="help-title">Sort, file, and forward mail automatically.</h3>
          <p className="help-body">
            Each rule is checked top-to-bottom against every incoming message. The first
            time all of a rule&rsquo;s conditions match, its actions run — and unless you ask
            it to continue, processing stops there.
          </p>
          <ul className="help-points">
            <li>
              <span className="help-points-key">Conditions</span> are joined with AND —
              every one must match.
            </li>
            <li>
              <span className="help-points-key">Move</span>, <span className="help-points-key">Copy</span>,
              <span className="help-points-key"> Archive</span> and <span className="help-points-key">Delete</span>
              {' '}are mutually exclusive — pick one destination per rule.
            </li>
            <li>
              <span className="help-points-key">Flag</span>, <span className="help-points-key">Mark as read</span>
              {' '}and <span className="help-points-key">Forward</span> can be combined with any non-delete destination.
            </li>
            <li>
              Drag the handle on the left of a rule to change <span className="help-points-key">precedence</span>.
            </li>
          </ul>
          <div className="help-foot">
            Changes save automatically.
          </div>
        </div>
      )}
    </div>
  );
}

function UserMenu({ accent, setAccent }) {
  const [open, setOpen] = useAS(false);
  const ref = useAR(null);
  useAE(() => {
    if (!open) return;
    const onDoc = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);
  return (
    <div className="user-menu-wrap" ref={ref}>
      <button className="avatar" title="chris@cabalmail.com" onClick={() => setOpen(o => !o)}>CC</button>
      {open && (
        <div className="user-menu" role="menu">
          <div className="user-menu-head">
            <div className="user-menu-avatar">CC</div>
            <div className="user-menu-who">
              <div className="user-menu-name">Chris Carr</div>
              <div className="user-menu-mail">chris@main.cabalmail.com</div>
            </div>
          </div>

          <div className="user-menu-section-label">Accent color</div>
          <div className="user-menu-accents">
            {USER_ACCENTS.map(c => (
              <button key={c}
                className={`accent-swatch ${accent === c ? 'active' : ''}`}
                data-c={c}
                onClick={() => setAccent(c)}
                title={c[0].toUpperCase() + c.slice(1)} />
            ))}
          </div>

          <div className="user-menu-sep" />
          <a className="user-menu-item" href="inbox-explorations.html">
            <Icon name="inbox" size={13} />
            <span>Back to mail</span>
          </a>
          <a className="user-menu-item current" href="rules.html" aria-current="page">
            <Icon name="rules" size={13} />
            <span>Mail rules…</span>
          </a>
          <button className="user-menu-item">
            <Icon name="settings" size={13} />
            <span>Preferences…</span>
          </button>
          <button className="user-menu-item">
            <Icon name="keyboard" size={13} />
            <span>Keyboard shortcuts</span>
            <span className="meta-kbd">?</span>
          </button>

          <div className="user-menu-sep" />
          <button className="user-menu-item"><span>Sign out</span></button>
        </div>
      )}
    </div>
  );
}

/* ============================================================
   App root
   ============================================================ */
function App() {
  const [tweaks, setTweaksRaw] = useAS(loadTweaks);
  const setTweaks = (patch) => setTweaksRaw(s => {
    const next = { ...s, ...patch };
    try { localStorage.setItem(LS_KEY, JSON.stringify(next)); } catch {}
    return next;
  });

  const [systemTheme, setSystemTheme] = useAS(() =>
    window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
  );
  useAE(() => {
    const mq = window.matchMedia?.('(prefers-color-scheme: dark)');
    if (!mq) return;
    const onChange = (e) => setSystemTheme(e.matches ? 'dark' : 'light');
    mq.addEventListener?.('change', onChange);
    return () => mq.removeEventListener?.('change', onChange);
  }, []);
  const effectiveTheme = tweaks.theme === 'system' ? systemTheme : tweaks.theme;

  const [showTweaks, setShowTweaks] = useAS(true);

  // Mobile single-pane swap. On desktop the data attribute is ignored.
  const [mobileView, setMobileView] = useAS('list');

  // Rules state ---------------------------------------------------------
  const [rules, setRulesRaw] = useAS(loadRules);
  const setRules = (next) => {
    const v = typeof next === 'function' ? next(rules) : next;
    saveRules(v);
    setRulesRaw(v);
  };
  const [selectedId, setSelectedId] = useAS(() => loadRules()[0]?.id || null);

  // Keep selectedId valid
  useAE(() => {
    if (!rules.find(r => r.id === selectedId)) {
      setSelectedId(rules[0]?.id || null);
    }
  }, [rules, selectedId]);

  const selectedRule = rules.find(r => r.id === selectedId) || null;

  // Mutators -----------------------------------------------------------
  const updateRule = (next) => {
    setRules(rs => rs.map(r => r.id === next.id ? next : r));
  };
  const addRule = (rule) => {
    const r = rule || blankRule();
    setRules(rs => [...rs, r]);
    setSelectedId(r.id);
    setMobileView('editor');
  };
  const deleteRule = (id) => {
    if (!confirm('Delete this rule? This cannot be undone.')) return;
    setRules(rs => rs.filter(r => r.id !== id));
  };
  const duplicateRule = (id) => {
    const r = rules.find(x => x.id === id);
    if (!r) return;
    const idx = rules.findIndex(x => x.id === id);
    const copy = { ...r, id: newRuleId(), name: r.name + ' (copy)' };
    const next = [...rules];
    next.splice(idx + 1, 0, copy);
    setRules(next);
    setSelectedId(copy.id);
    setMobileView('editor');
  };
  const toggleRule = (id, v) => {
    setRules(rs => rs.map(r => r.id === id ? { ...r, enabled: v } : r));
  };
  const reorder = (fromId, toId, edge) => {
    const fromIdx = rules.findIndex(r => r.id === fromId);
    const toIdx = rules.findIndex(r => r.id === toId);
    if (fromIdx === -1 || toIdx === -1) return;
    const next = [...rules];
    const [moved] = next.splice(fromIdx, 1);
    let insertAt = next.findIndex(r => r.id === toId);
    if (edge === 'below') insertAt += 1;
    next.splice(insertAt, 0, moved);
    setRules(next);
  };

  // Host (Tweaks toolbar) postMessage protocol
  useAE(() => {
    const onMsg = (e) => {
      if (e.data?.type === '__activate_edit_mode') setShowTweaks(true);
      if (e.data?.type === '__deactivate_edit_mode') setShowTweaks(false);
    };
    window.addEventListener('message', onMsg);
    window.parent?.postMessage({ type: '__edit_mode_available' }, '*');
    return () => window.removeEventListener('message', onMsg);
  }, []);
  useAE(() => {
    window.parent?.postMessage({ type: '__edit_mode_set_keys', edits: tweaks }, '*');
  }, [tweaks.theme, tweaks.accent, tweaks.density, tweaks.conditionStyle, tweaks.actionStyle, tweaks.orderingStyle]);

  const isEmpty = rules.length === 0;

  return (
    <div
      className="app"
      data-direction="stately"
      data-theme={effectiveTheme}
      data-accent={tweaks.accent}
      data-density={tweaks.density}
    >
      {/* ──── Topbar ──────────────────────────────────────────── */}
      <header className="topbar">
        <a className="brand" href="inbox-explorations.html" title="Back to mail">
          <span className="brand-logo-tile" aria-label="Cabalmail">
            <svg className="brand-logo" viewBox="0 0 200 100" fill="currentColor" shapeRendering="crispEdges" aria-hidden="true">
              <path d={LOGO_PATH_D} />
            </svg>
          </span>
          <span className="brand-word">Cabalmail</span>
        </a>
        <nav className="crumbs">
          <a href="inbox-explorations.html">Mail</a>
          <span className="sep">/</span>
          <span className="here">Rules</span>
        </nav>
        <div className="topbar-right">
          <HelpMenu />
          <UserMenu accent={tweaks.accent} setAccent={(c) => setTweaks({ accent: c })} />
        </div>
      </header>

      {/* ──── Workspace ──────────────────────────────────────── */}
      <div className="workspace" data-mobile-view={mobileView}>
        {isEmpty ? (
          <>
            <aside className="rules-pane">
              <div className="rules-head">
                <div className="rules-head-title">Rules</div>
                <div className="rules-head-meta">0/0</div>
              </div>
              <div style={{ padding: 22, fontSize: 12, color: 'var(--ink-quiet)', fontFamily: 'var(--font-reader)', fontStyle: 'italic', lineHeight: 1.5 }}>
                Your rules will appear here in the order they run.
              </div>
              <div className="rules-list-foot">
                <button className="btn primary" onClick={() => addRule()}>
                  <Icon name="plus" size={13} />
                  <span>New rule</span>
                </button>
              </div>
            </aside>
            <section className="editor-pane">
              <EmptyState
                onCreateBlank={() => addRule()}
                onUseTemplate={(t) => addRule(t.build())}
              />
            </section>
          </>
        ) : (
          <>
            <RulesList
              rules={rules}
              selectedId={selectedId}
              onSelect={(id) => { setSelectedId(id); setMobileView('editor'); }}
              onReorder={reorder}
              onToggle={toggleRule}
              onAdd={() => addRule()}
              orderingStyle={tweaks.orderingStyle}
            />
            <section className="editor-pane">
              {selectedRule ? (
                <RuleEditor
                  rule={selectedRule}
                  setRule={updateRule}
                  onDelete={() => deleteRule(selectedRule.id)}
                  onDuplicate={() => duplicateRule(selectedRule.id)}
                  onBack={() => setMobileView('list')}
                  conditionStyle={tweaks.conditionStyle}
                  actionStyle={tweaks.actionStyle}
                />
              ) : (
                <div className="editor-empty">Select a rule on the left, or create a new one.</div>
              )}
            </section>
          </>
        )}
      </div>

      {/* ──── Tweaks ─────────────────────────────────────────── */}
      {showTweaks ? (
        <TweaksPanel state={tweaks} setState={setTweaks} onClose={() => setShowTweaks(false)} />
      ) : (
        <button className="toggle-pill" onClick={() => setShowTweaks(true)}>
          <Icon name="settings" size={13} /> Tweaks
        </button>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
