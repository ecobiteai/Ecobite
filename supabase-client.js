/* ============================================================
   EcoBite — shared Supabase client
   Loaded after the supabase-js CDN script on every page that
   needs accounts (signup.html, signin.html, home.html).
   The publishable key is safe to expose in client code — it's
   the browser-facing key, not the secret one.
   ============================================================ */

const SUPABASE_URL = 'https://vzsvhkizlftkdytwetgj.supabase.co';
const SUPABASE_KEY = 'sb_publishable_WRsOp_iHw0Ls13MD5UTaqQ_g0YA2yWB';

// Use one explicit browser-local session store across every EcoBite page.
// This preserves the refresh token when the site is reloaded, so a signed-in
// user stays signed in until they choose Sign out.
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storage: window.localStorage,
    storageKey: 'ecobite-auth-session'
  }
});

// Set window.ECOBITE_API_URL before this script in production, for example:
// window.ECOBITE_API_URL = 'https://api.your-domain.com';
// Local development falls back to the FastAPI server.
const ECOBITE_API_URL = window.ECOBITE_API_URL || 'http://localhost:8000';

async function ecoApi(path, options = {}) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('Sign in is required.');
  const response = await fetch(ECOBITE_API_URL + path, {
    ...options,
    headers: {
      Authorization: `Bearer ${session.access_token}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {})
    }
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    throw new Error(detail.detail || 'EcoBite could not complete that request.');
  }
  return response.status === 204 ? null : response.json();
}
