/**
 * Tunable weights and thresholds for the sign-up/sign-in classifier.
 * The starting numbers follow the reliability ranking in
 * docs/1.x/browser-extension-plan.md ("Sign Up vs Sign In detection");
 * tuning happens against the fixture corpus, not per-site.
 */

export const WEIGHTS = {
  newPasswordAutocomplete: 3.0,
  currentPasswordAutocomplete: 3.0,
  twoPasswordFields: 3.0,
  signupButtonText: 2.0,
  signinButtonText: 2.0,
  formActionUrl: 1.5,
  pageUrl: 1.5,
  headingText: 1.5,
  fieldLabels: 1.5,
  // Structural, so it sits with the other context signals rather than in the
  // password-shaped 3.0 tier: on its own it can lift a mislabelled sign-up
  // form out of `signin` into `ambiguous` (a badge the user can click), but
  // never on its own into `signup` (an automatic offer).
  multipleIdentityFields: 1.5,
  termsCheckbox: 0.5,
} as const;

/** Score at or above which a form is classified `signup`. */
export const SIGNUP_THRESHOLD = 2.0;
/** Score at or below which a form is classified `signin`. */
export const SIGNIN_THRESHOLD = -1.5;

/** Localized sign-up vocabulary (lowercased substrings). */
export const SIGNUP_TERMS = [
  'sign up',
  'signup',
  'create account',
  'create an account',
  'create your account',
  'create my account',
  'register',
  'get started',
  'join',
  'inscrivez-vous',
  "s'inscrire",
  'registrieren',
  'anmelden',
  'konto erstellen',
  'crear cuenta',
  'regístrate',
  'registrarse',
  'cadastre-se',
  'criar conta',
  'registrati',
  'aanmelden',
  'account aanmaken',
  '登録',
  'アカウント作成',
  '注册',
  '가입',
];

/** Localized sign-in vocabulary (lowercased substrings). */
export const SIGNIN_TERMS = [
  'sign in',
  'signin',
  'log in',
  'login',
  'log on',
  'connexion',
  'se connecter',
  'einloggen',
  'iniciar sesión',
  'entrar',
  'accedi',
  'inloggen',
  'ログイン',
  '登录',
  '로그인',
];

/** URL-path fragments suggesting sign-up. */
export const SIGNUP_PATH_TERMS = ['signup', 'sign-up', 'sign_up', 'register', 'registration', 'join', 'create-account', 'create_account', 'getstarted', 'get-started'];

/** URL-path fragments suggesting sign-in. */
export const SIGNIN_PATH_TERMS = ['signin', 'sign-in', 'sign_in', 'login', 'log-in', 'log_in', 'logon', 'session'];
