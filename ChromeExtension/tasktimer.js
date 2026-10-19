// Talks to the TaskTimer team database (Supabase) as the signed-in person.
// The anon key is public by design; what each person can read or change is enforced
// by the database rules in Supabase/schema.sql.
const TT = (() => {
  const URL = 'https://lxsjwiqhfotbowsgcexs.supabase.co';
  const KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4c2p3aXFoZm90Ym93c2djZXhzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0Mjg3NjgsImV4cCI6MjEwODAwNDc2OH0.LbgdJQ-7uk43qBVtL1FhTXB7n70Xe-D6see7cwDhRd0';

  async function session() {
    const { ttSession } = await chrome.storage.local.get('ttSession');
    return ttSession || null;
  }

  async function save(s) {
    if (s) await chrome.storage.local.set({ ttSession: s });
    else await chrome.storage.local.remove('ttSession');
  }

  function message(j, status) {
    return (j && (j.error_description || j.msg || j.message || j.error)) || `Server error ${status}`;
  }

  async function auth(path, body) {
    const r = await fetch(`${URL}/auth/v1/${path}`, {
      method: 'POST',
      headers: { apikey: KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(message(j, r.status));
    const s = {
      access: j.access_token,
      refresh: j.refresh_token,
      expires: Date.now() + (j.expires_in || 3600) * 1000,
      userId: j.user && j.user.id,
      email: j.user && j.user.email,
    };
    await save(s);
    return s;
  }

  let refreshing = null;
  async function token() {
    const s = await session();
    if (!s) throw new Error('signed-out');
    if (s.expires - Date.now() > 60000) return s;
    if (!refreshing) {
      refreshing = auth('token?grant_type=refresh_token', { refresh_token: s.refresh })
        .catch(async (e) => {
          if (/refresh|invalid/i.test(e.message)) await save(null);
          throw e;
        })
        .finally(() => { refreshing = null; });
    }
    return refreshing;
  }

  async function rest(method, path, body, prefer) {
    const s = await token();
    const headers = { apikey: KEY, Authorization: `Bearer ${s.access}`, 'Content-Type': 'application/json' };
    if (prefer) headers.Prefer = prefer;
    const r = await fetch(`${URL}/rest/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await r.text();
    const j = text ? JSON.parse(text) : null;
    if (!r.ok) throw new Error(message(j, r.status));
    return j;
  }

  return {
    session,
    signIn: (email, password) => auth('token?grant_type=password', { email, password }),
    signOut: () => save(null),
    rest,
    userId: async () => (await session())?.userId,
  };
})();
