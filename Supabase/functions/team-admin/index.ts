// TaskTimer — team-admin Edge Function
// Team leaders: create accounts for their team, add an existing account, reset a member's
// password, take someone off the team.
// Admins (profiles.is_admin): see every account and team, create accounts for any team,
// move people between teams, change roles, reset passwords, create / rename / delete teams.
// The service_role key never leaves Supabase.
//
// Deploy: Supabase → Edge Functions → team-admin → Code → paste this file → Deploy.

import { createClient } from "npm:@supabase/supabase-js@2";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const ROLES = ["member", "leader"];

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
    .from("profiles").select("id, role, team_id, is_admin").eq("id", who.user.id).single();
  if (!me) return json({ error: "Please sign in again." }, 401);
  const isAdmin = me.is_admin === true;
  const isLeader = me.role === "leader" && !!me.team_id;

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const action = String(body.action ?? "");

  const email = () => String(body.email ?? "").trim().toLowerCase();
  const checkPassword = (p: string) =>
    p.length < 6 ? json({ error: "The password needs at least 6 characters." }, 400) : null;

  async function byEmail(e: string) {
    const { data } = await admin
      .from("profiles").select("id, team_id, full_name").eq("email", e).maybeSingle();
    return data;
  }

  async function newAccount(e: string, password: string, name: string, teamID: string | null, role: string) {
    const { data, error } = await admin.auth.admin.createUser({
      email: e,
      password,
      email_confirm: true,
      user_metadata: { full_name: name },
    });
    if (error || !data.user) return { error: error?.message ?? "Couldn't create the account." };
    // The profile row is made by the database trigger; set team and role.
    const { error: e2 } = await admin.from("profiles").upsert({
      id: data.user.id, email: e, full_name: name, team_id: teamID, role,
    });
    if (e2) return { error: e2.message };
    return { id: data.user.id };
  }

  // ───────────── Admin ─────────────

  if (action.startsWith("admin_")) {
    if (!isAdmin) return json({ error: "Only an admin can do this." }, 403);

    if (action === "admin_list") {
      const { data: profiles, error } = await admin
        .from("profiles").select("id, email, full_name, role, team_id, is_admin, created_at")
        .order("full_name");
      if (error) return json({ error: error.message }, 400);
      const { data: teams } = await admin.from("teams").select("id, name, created_at").order("name");
      // Last sign-in comes from Auth.
      const signIns: Record<string, string | null> = {};
      for (let page = 1; page <= 10; page++) {
        const { data } = await admin.auth.admin.listUsers({ page, perPage: 200 });
        const users = data?.users ?? [];
        for (const u of users) signIns[u.id] = u.last_sign_in_at ?? null;
        if (users.length < 200) break;
      }
      return json({
        profiles: (profiles ?? []).map((p) => ({ ...p, last_sign_in_at: signIns[p.id] ?? null })),
        teams: teams ?? [],
      });
    }

    if (action === "admin_create_user") {
      const e = email();
      const name = String(body.name ?? "").trim();
      const password = String(body.password ?? "");
      const role = String(body.role ?? "member");
      const teamID = body.team_id ? String(body.team_id) : null;
      if (!EMAIL.test(e)) return json({ error: "That email isn't valid (it should look like name@company.com)." }, 400);
      if (!name) return json({ error: "Enter the name." }, 400);
      const bad = checkPassword(password); if (bad) return bad;
      if (!ROLES.includes(role)) return json({ error: "Unknown role." }, 400);
      if (await byEmail(e)) return json({ error: "There's already an account with this email." }, 409);
      const r = await newAccount(e, password, name, teamID, role);
      if (r.error) return json({ error: r.error }, 400);
      if (body.is_admin === true) await admin.from("profiles").update({ is_admin: true }).eq("id", r.id);
      return json({ ok: true, id: r.id });
    }

    if (action === "admin_update_user") {
      const id = String(body.id ?? "");
      const { data: target } = await admin.from("profiles").select("id, is_admin").eq("id", id).maybeSingle();
      if (!target) return json({ error: "Account not found." }, 404);
      const patch: Record<string, unknown> = {};
      if ("team_id" in body) patch.team_id = body.team_id ? String(body.team_id) : null;
      if ("role" in body) {
        const role = String(body.role);
        if (!ROLES.includes(role)) return json({ error: "Unknown role." }, 400);
        patch.role = role;
      }
      if ("full_name" in body) {
        const n = String(body.full_name ?? "").trim();
        if (!n) return json({ error: "The name can't be empty." }, 400);
        patch.full_name = n;
      }
      if ("is_admin" in body) {
        const on = body.is_admin === true;
        if (!on && target.is_admin) {
          const { count } = await admin.from("profiles").select("id", { count: "exact", head: true }).eq("is_admin", true);
          if ((count ?? 0) <= 1) return json({ error: "There has to be at least one admin." }, 400);
        }
        patch.is_admin = on;
      }
      if (!Object.keys(patch).length) return json({ ok: true });
      const { error } = await admin.from("profiles").update(patch).eq("id", id);
      if (error) return json({ error: error.message }, 400);
      if ("team_id" in patch && patch.team_id) {
        // Older versions locked removed members out; undo that.
        await admin.auth.admin.updateUserById(id, { ban_duration: "none" });
      }
      return json({ ok: true });
    }

    if (action === "admin_reset") {
      const id = String(body.id ?? "");
      const password = String(body.password ?? "");
      const bad = checkPassword(password); if (bad) return bad;
      const { error } = await admin.auth.admin.updateUserById(id, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action === "admin_create_team") {
      const name = String(body.name ?? "").trim();
      if (!name) return json({ error: "Enter the team name." }, 400);
      const { data, error } = await admin.from("teams").insert({ name }).select("id").single();
      if (error) {
        return json({ error: error.code === "23505" ? "A team with this name already exists." : error.message }, 400);
      }
      return json({ ok: true, id: data.id });
    }

    if (action === "admin_rename_team") {
      const name = String(body.name ?? "").trim();
      if (!name) return json({ error: "Enter the team name." }, 400);
      const { error } = await admin.from("teams").update({ name }).eq("id", String(body.id ?? ""));
      if (error) {
        return json({ error: error.code === "23505" ? "A team with this name already exists." : error.message }, 400);
      }
      return json({ ok: true });
    }

    if (action === "admin_delete_team") {
      const id = String(body.id ?? "");
      const { count } = await admin.from("profiles").select("id", { count: "exact", head: true }).eq("team_id", id);
      if ((count ?? 0) > 0) return json({ error: "Move everyone out of this team first." }, 400);
      const { error } = await admin.from("teams").delete().eq("id", id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: "Unknown action." }, 400);
  }

  // ───────────── Team leader ─────────────

  if (!isLeader) return json({ error: "Only a team leader can do this." }, 403);

  // A member of the leader's own team (never another team, never the leader themself).
  async function teammate(id: string) {
    const { data } = await admin
      .from("profiles").select("id, team_id, role, email").eq("id", id).single();
    if (!data || data.team_id !== me!.team_id) return null;
    if (data.id === me!.id) return null;
    return data;
  }

  // Someone who already has an account and isn't in a team: put them in the leader's team.
  async function addExisting(existing: { id: string; team_id: string | null }) {
    if (existing.team_id === me!.team_id) return json({ error: "Already in your team." }, 409);
    if (existing.team_id) {
      return json({ error: "This person is in another team. Their team leader (or an admin) needs to remove them first." }, 409);
    }
    const { error } = await admin.from("profiles")
      .update({ team_id: me!.team_id, role: "member" }).eq("id", existing.id);
    if (error) return json({ error: error.message }, 400);
    // Older versions locked removed members out; undo that.
    await admin.auth.admin.updateUserById(existing.id, { ban_duration: "none" });
    return json({ ok: true, id: existing.id, existing: true });
  }

  if (action === "create") {
    const e = email();
    const password = String(body.password ?? "");
    const name = String(body.name ?? "").trim();
    if (!EMAIL.test(e)) return json({ error: "That email isn't valid (it should look like name@company.com)." }, 400);
    const bad = checkPassword(password); if (bad) return bad;
    if (!name) return json({ error: "Enter the member's name." }, 400);

    const existing = await byEmail(e);
    if (existing) return await addExisting(existing);

    const r = await newAccount(e, password, name, me.team_id, "member");
    if (r.error) return json({ error: r.error }, 400);
    return json({ ok: true, id: r.id });
  }

  if (action === "add_existing") {
    const e = email();
    if (!EMAIL.test(e)) return json({ error: "That email isn't valid (it should look like name@company.com)." }, 400);
    const existing = await byEmail(e);
    if (!existing) return json({ error: "There's no TaskTimer account with this email. Create a new one instead." }, 404);
    const r = await addExisting(existing);
    if (r.status === 200) {
      return json({ ok: true, id: existing.id, existing: true, name: existing.full_name ?? e });
    }
    return r;
  }

  if (action === "reset") {
    const t = await teammate(String(body.id ?? ""));
    if (!t) return json({ error: "That person isn't in your team." }, 403);
    const password = String(body.password ?? "");
    const bad = checkPassword(password); if (bad) return bad;
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
