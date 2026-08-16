/* ============================================================
   Cabalmail Mail rules — shared data + Icon set
   ============================================================ */

const Icon = ({ name, size = 16, className = '' }) => {
  const paths = {
    inbox: <path d="M3 13h4l1.5 2h5L15 13h4M3 13V5a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v8M3 13v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4" />,
    archive: <><rect x="3" y="5" width="16" height="3" rx="1" /><path d="M5 8v10a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V8" /><path d="M9 12h4" /></>,
    trash: <><path d="M4 6h14M9 6V4h4v2M6 6l1 13h8l1-13" /><path d="M10 10v6M12 10v6" /></>,
    folder: <path d="M3 6a1 1 0 0 1 1-1h4l2 2h8a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6z" />,
    copy: <><rect x="6" y="6" width="12" height="12" rx="1.5" /><path d="M14 6V4a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h2" /></>,
    star: <path d="M11 3l2.5 5.2 5.5.8-4 4 1 5.5-5-2.7-5 2.7 1-5.5-4-4 5.5-.8L11 3z" />,
    forward: <path d="M12 6l6 5-6 5M18 11H9a5 5 0 0 0-5 5" />,
    markRead: <><path d="M3 7l8 5 8-5" /><rect x="3" y="5" width="16" height="13" rx="2" /><path d="M7 11l2 2 5-5" /></>,
    plus: <><path d="M11 5v12M5 11h12" /></>,
    minus: <path d="M5 11h12" />,
    close: <path d="M5 5l12 12M17 5L5 17" />,
    check: <path d="M5 11l4 4 8-8" />,
    chevronDown: <path d="M6 8l5 5 5-5" />,
    chevronUp: <path d="M6 14l5-5 5 5" />,
    chevronRight: <path d="M8 6l5 5-5 5" />,
    chevronLeft: <path d="M14 6l-5 5 5 5" />,
    drag: <>
      <circle cx="8" cy="5"  r="1" fill="currentColor" stroke="none" />
      <circle cx="8" cy="11" r="1" fill="currentColor" stroke="none" />
      <circle cx="8" cy="17" r="1" fill="currentColor" stroke="none" />
      <circle cx="14" cy="5"  r="1" fill="currentColor" stroke="none" />
      <circle cx="14" cy="11" r="1" fill="currentColor" stroke="none" />
      <circle cx="14" cy="17" r="1" fill="currentColor" stroke="none" />
    </>,
    settings: <><circle cx="11" cy="11" r="3" /><path d="M11 2v3M11 17v3M2 11h3M17 11h3M4.5 4.5l2 2M15.5 15.5l2 2M4.5 17.5l2-2M15.5 6.5l2-2" /></>,
    rules: <>
      <path d="M3 6h12M3 11h8M3 16h5" />
      <circle cx="18" cy="6" r="2" />
      <circle cx="14" cy="11" r="2" />
      <circle cx="11" cy="16" r="2" />
    </>,
    info: <><circle cx="11" cy="11" r="8" /><path d="M11 10v5" /><circle cx="11" cy="7" r="0.7" fill="currentColor" /></>,
    help: <><circle cx="11" cy="11" r="8" /><path d="M8.5 8.5a2.5 2.5 0 1 1 4.5 1.5c-.7.8-1.5 1-1.5 2.2v0.3" /><circle cx="11" cy="15.5" r="0.8" fill="currentColor" stroke="none" /></>,
    duplicate: <><rect x="3" y="3" width="11" height="11" rx="1.5" /><rect x="8" y="8" width="11" height="11" rx="1.5" /></>,
    play: <path d="M7 5l10 6-10 6V5z" />,
    keyboard: <><rect x="2" y="6" width="18" height="11" rx="2" /><path d="M5 10h.01M8 10h.01M11 10h.01M14 10h.01M17 10h.01M5 13h.01M14 13h.01M17 13h.01M8 13h6" /></>,
    arrowRight: <path d="M5 11h12M13 7l4 4-4 4" />,
  };
  return (
    <svg
      className={`icon icon-${name} ${className}`}
      width={size} height={size} viewBox="0 0 22 22"
      fill="none" stroke="currentColor" strokeWidth="1.5"
      strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name] || null}
    </svg>
  );
};

// Folder list — matches the inbox seed
const FOLDERS = [
  'Inbox',
  'Archive',
  'Sent',
  'Drafts',
  'Junk',
  'Trash',
  'Receipts',
  'Travel',
  'Newsletters',
  'Work',
  'Work/Cabalmail',
  'Work/AWS',
  'Bills',
  'CI alerts',
];

// Seed rules — realistic procmail-style automation
const FIELDS = [
  { value: 'from',    label: 'From',    rowLabel: 'From address contains' },
  { value: 'to',      label: 'To',      rowLabel: 'To address contains' },
  { value: 'cc',      label: 'CC',      rowLabel: 'CC address contains' },
  { value: 'bcc',     label: 'BCC',     rowLabel: 'BCC address contains' },
  { value: 'subject', label: 'Subject', rowLabel: 'Subject contains' },
  { value: 'body',    label: 'Body',    rowLabel: 'Body contains' },
];

const FIELD_LABEL = Object.fromEntries(FIELDS.map(f => [f.value, f.label]));

function newRuleId() {
  return 'r-' + Math.random().toString(36).slice(2, 8);
}

function blankRule(over = {}) {
  return {
    id: newRuleId(),
    name: 'Untitled rule',
    enabled: true,
    conditions: [{ field: 'from', value: '' }],
    action: 'move',     // 'move' | 'copy' | 'delete' | 'archive'
    moveFolder: 'Inbox',
    copyFolders: [],
    flag: false,
    markRead: false,
    forward: [],
    continueToNext: false,
    ...over,
  };
}

const SEED_RULES = [
  {
    id: 'r-aws',
    name: 'AWS billing → Receipts',
    enabled: true,
    conditions: [
      { field: 'from',    value: 'aws.amazon.com' },
      { field: 'subject', value: 'invoice' },
    ],
    action: 'move',
    moveFolder: 'Receipts',
    copyFolders: [],
    flag: false,
    markRead: true,
    forward: [],
    continueToNext: false,
  },
  {
    id: 'r-stripe',
    name: 'Stripe receipts → Receipts',
    enabled: true,
    conditions: [
      { field: 'from', value: 'receipts@stripe.com' },
    ],
    action: 'move',
    moveFolder: 'Receipts',
    copyFolders: [],
    flag: false,
    markRead: true,
    forward: [],
    continueToNext: false,
  },
  {
    id: 'r-github',
    name: 'GitHub notifications',
    enabled: true,
    conditions: [
      { field: 'from', value: 'notifications@github.com' },
    ],
    action: 'move',
    moveFolder: 'Work/Cabalmail',
    copyFolders: [],
    flag: false,
    markRead: false,
    forward: [],
    continueToNext: true,
  },
  {
    id: 'r-ci',
    name: 'CI failures → Slack',
    enabled: true,
    conditions: [
      { field: 'from',    value: 'noreply@github.com' },
      { field: 'subject', value: 'failed' },
    ],
    action: 'copy',
    moveFolder: '',
    copyFolders: ['CI alerts'],
    flag: true,
    markRead: false,
    forward: ['oncall@cabalmail.com'],
    continueToNext: true,
  },
  {
    id: 'r-maya',
    name: 'Flag mail from Maya',
    enabled: true,
    conditions: [
      { field: 'from', value: 'maya@steadystate.so' },
    ],
    action: 'move',
    moveFolder: 'Inbox',
    copyFolders: [],
    flag: true,
    markRead: false,
    forward: [],
    continueToNext: true,
  },
  {
    id: 'r-newsletters',
    name: 'Newsletters → Archive',
    enabled: false,
    conditions: [
      { field: 'from', value: 'newsletter' },
    ],
    action: 'archive',
    moveFolder: '',
    copyFolders: [],
    flag: false,
    markRead: true,
    forward: [],
    continueToNext: false,
  },
  {
    id: 'r-unsub',
    name: 'Old unsubscribe loops → Trash',
    enabled: true,
    conditions: [
      { field: 'subject', value: 'unsubscribe confirmation' },
    ],
    action: 'delete',
    moveFolder: '',
    copyFolders: [],
    flag: false,
    markRead: false,
    forward: [],
    continueToNext: false,
  },
];

const TEMPLATES = [
  {
    name: 'File billing receipts',
    desc: 'From contains "invoice"\n→ Move to Receipts, mark read',
    build: () => blankRule({
      name: 'Billing receipts',
      conditions: [{ field: 'subject', value: 'invoice' }],
      action: 'move', moveFolder: 'Receipts', markRead: true,
    }),
  },
  {
    name: 'Quiet noisy newsletters',
    desc: 'From contains "newsletter"\n→ Archive, mark read',
    build: () => blankRule({
      name: 'Quiet newsletters',
      conditions: [{ field: 'from', value: 'newsletter' }],
      action: 'archive', markRead: true,
    }),
  },
  {
    name: 'Flag mail from your team',
    desc: 'From contains "@yourteam.com"\n→ Flag, continue',
    build: () => blankRule({
      name: 'Team flag',
      conditions: [{ field: 'from', value: '@example.com' }],
      action: 'move', moveFolder: 'Inbox',
      flag: true, continueToNext: true,
    }),
  },
];

// Describe a rule in one mono-spaced line — used in the master list
function describeRule(r) {
  const conds = r.conditions
    .filter(c => c.value.trim())
    .map(c => `${FIELD_LABEL[c.field].toLowerCase()}~"${c.value}"`)
    .join(' & ');
  let act = '';
  if (r.action === 'move') act = `→ ${r.moveFolder || '?'}`;
  else if (r.action === 'copy') act = `↳ ${(r.copyFolders[0] || '?')}${r.copyFolders.length > 1 ? ` +${r.copyFolders.length - 1}` : ''}`;
  else if (r.action === 'delete') act = '✕ delete';
  else if (r.action === 'archive') act = '⤓ archive';
  const extras = [
    r.markRead && 'read',
    r.flag && 'flag',
    r.forward.length && `fwd×${r.forward.length}`,
  ].filter(Boolean);
  return `${conds || 'no condition'}  ${act}${extras.length ? '  · ' + extras.join('·') : ''}`;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
function isValidEmail(s) { return EMAIL_RE.test(s.trim()); }

// Make available to other babel scripts (each gets a fresh scope after transpile)
Object.assign(window, {
  Icon, FOLDERS, FIELDS, FIELD_LABEL,
  SEED_RULES, TEMPLATES,
  blankRule, newRuleId, describeRule, isValidEmail,
});
