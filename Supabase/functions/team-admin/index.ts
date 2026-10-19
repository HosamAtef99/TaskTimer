// TaskTimer — team-admin Edge Function
// Lets a team leader create accounts for their team, reset a member's password,
// or take someone off the team. The admin key never leaves Supabase.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via Editor,
// name it exactly  team-admin , paste this file, Deploy.

import { createClient } from "npm:@supabase/supabase-js@2";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  // Who is calling?
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who } = await admin.auth.getUser(jwt);
  if (!who?.user) return json({ error: "Please sign in again." }, 401);

  const { data: me } = await admin
    .from("profiles").select("id, role, team_id").eq("id", who.user.id).single();
  if (!me || me.role !== "leader" || !me.team_id) {
    return json({ error: "Only a team leader can do this." }, 403);
  }

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const action = String(body.action ?? "");

  // A member of the leader's own team (never another team, never the leader themself).
  async function teammate(id: string) {
    const { data } = await admin
      .from("profiles").select("id, team_id, role, email").eq("id", id).single();
    if (!data || data.team_id !== me!.team_id) return null;
    if (data.id === me!.id) return null;
    return data;
  }

  if (action === "create") {
    const email = String(body.email ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    const name = String(body.name ?? "").trim();
    if (!email.includes("@")) return json({ error: "Enter a valid email." }, 400);
    if (password.length < 6) return json({ error: "The password needs at least 6 characters." }, 400);
    if (!name) return json({ error: "Enter the member's name." }, 400);

    // Someone who already has an account (e.g. left another team): add them, keep their password.
    const { data: existing } = await admin
      .from("profiles").select("id, team_id").eq("email", email).maybeSingle();
    if (existing) {
      if (existing.team_id === me.team_id) return json({ error: "Already in your team." }, 409);
      if (existing.team_id) {
        return json({ error: "This person is in another team. Their team leader needs to remove them first." }, 409);
      }
      const { error: e1 } = await admin.from("profiles")
        .update({ team_id: me.team_id, role: "member" }).eq("id", existing.id);
      if (e1) return json({ error: e1.message }, 400);
      // Older versions locked removed members out; undo that.
      await admin.auth.admin.updateUserById(existing.id, { ban_duration: "none" });
      return json({ ok: true, id: existing.id, existing: true });
    }

    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: name },
    });
    if (error || !data.user) return json({ error: error?.message ?? "Couldn't create the account." }, 400);

    // The profile row is made by the database trigger; put it in the leader's team.
    const { error: e2 } = await admin.from("profiles").upsert({
      id: data.user.id,
      email,
      full_name: name,
      team_id: me.team_id,
      role: "member",
    });
    if (e2) return json({ error: e2.message }, 400);
    return json({ ok: true, id: data.user.id });
  }

  if (action === "reset") {
    const t = await teammate(String(body.id ?? ""));
    if (!t) return json({ error: "That person isn't in your team." }, 403);
    const password = String(body.password ?? "");
    if (password.length < 6) return json({ error: "The password needs at least 6 characters." }, 400);
    const { error } = await admin.auth.admin.updateUserById(t.id, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (action === "remove") {
    const t = await teammate(String(body.id ?? ""));
    if (!t) return json({ error: "That person isn't in your team." }, 403);
    // Off the team. The account stays (another leader can add them), and their past
    // tasks stay with this team's history.
    const { error } = await admin.from("profiles").update({ team_id: null }).eq("id", t.id);
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  return json({ error: "Unknown action." }, 400);
});
