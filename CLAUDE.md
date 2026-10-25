# TaskTimer Dev — notes for Claude (and people)

Read this before changing anything. Hosam and Mousab both work on this repo, each with
their own Claude. This file is how decisions made in one person's chats reach the other.
When you make a decision that the other person would need to know, add it here.

## What this is
- **TaskTimer Dev**: macOS menu-bar + window time tracker for an animation team
  (bundle id `com.hosam.tasktimer.dev`). It's Hosam's test fork of
  [mo-animation/TaskTimer](https://github.com/mo-animation/TaskTimer) (Mousab's original).
- People time tasks and amends ("Task - Amend N"). Statuses: Incoming → In Progress → Completed.
- Team leaders see their team's tasks and live timers on Supabase.
- A Chrome extension logs finished tasks on **Modhesh** (the company task platform,
  `modhesh.social-eyez.com`).

## Build and release
- Swift + SwiftUI, macOS 13+. Built with **swiftc only, no Xcode project**:
  `Build TaskTimer.command` compiles `Sources/*.swift`. Every new `.swift` file in `Sources/`
  is picked up automatically.
- There's no Swift toolchain on Linux: you can't compile in a cloud session. Push and let
  GitHub Actions build it. A failed build shows up in the Actions log.
- `@State` isn't available (it's a macro that needs full Xcode). **Use `@Local`**
  (`Sources/Local.swift`) everywhere you'd use `@State`.
- `.github/workflows/release.yml` builds a universal app on every push to `main`, on
  `macos-15-intel`, because the Apple Silicon runners kept timing out.
- **A release happens only when `Resources/VERSION` changes.** The app's updater
  (`Sources/Updater.swift`, repo `HosamAtef99/TaskTimer`) then offers it to *everyone*.
  So bump VERSION only when you mean to ship, agree on it first, and add a section at the
  top of `CHANGELOG.md`: its top section becomes the release notes.
- The release also ships `TaskTimer-Chrome.zip`, and the app bundles `ChromeExtension/`
  in its Resources.

## Working together
- Pull before you start.
- **Hosam's sessions commit straight to `main`** (his call). Mousab decides for his own;
  a branch + Pull Request is still a good idea for big or risky changes.
- Commit messages: short, say what changed for the user.

## Code map (Sources/)
| File | What |
|---|---|
| `Models.swift` | `TaskItem` (`parentID` = amend, `workDate`, `deliverables`, `rating`, `challenge`, `wantsFolder`…), `TaskStatus` |
| `Store.swift` | All local state; per-account data file `data-<uid>.json` (the first account on a Mac claims the old `data.json`); `switchAccount`, folders, `complete(...)` |
| `MainView.swift` | Main window. Responsive: the width comes from a root `GeometryReader` (window width, **not** content width). `compact` < 780, `narrow` < 640. Filters: status, month (creation date), Modhesh (closed / not closed / not linked) |
| `Sheets.swift` | New Task, Done (hours/min rounded to ½ h, deliverables, stars, challenge) |
| `FolderService.swift` / `MonthFolder.swift` | Task folders (client folder or months root; the month folder name copies the style of the existing ones). Dropped files are sorted into subfolders by type, moved or copied (the user picks in `DropFilesSheet`, in `MainView.swift`) |
| `AfterEffects.swift` | Imports dropped files into the open AE project through AppleScript `DoScript` |
| `AERenderHelper.swift` | Puts a small ExtendScript helper into the running AE (`app.scheduleTask`, every 2 s, `$.global.TaskTimerRQ`): Render Queue items added in a task's project get their output set to the task's Render folder. Added once per AE launch (max 2 tries, no `activate`), setting `Pref.aeRenderToTask` |
| `Cloud.swift` / `CloudSync.swift` | Supabase auth + REST, push/pull, team, Modhesh state, weekly report |
| `TeamView.swift` | Leader window: tasks, summary, add member (new account, or an existing account by email), reset/remove member, assign task, CSV. `isValidEmail` / `EmailHint` live here |
| `AdminView.swift` | Admin panel — the **main window for admin accounts** (`AdminView(embedded: true)` in `MainView`). Tabs: Hours (every team's and person's hours / done / in progress / working now for a month, per-person task list, CSV), People (move between teams, set role, reset password, unblock, delete account for good), Teams (create / rename / delete empty) |
| `ModheshView.swift` | Link Modhesh tasks to TaskTimer tasks or amends (manual only) |
| `ExtensionInstaller.swift` | Copies the bundled extension to `~/Library/Application Support/TaskTimer Dev/…`, opens `chrome://extensions` through AppleScript, detects the installed extension from Chrome's prefs |
| `RenderWatcher.swift` | "Render finished" notification with Stop/Done. Watches a task's Render folder while the task or any amend is in progress; new **or overwritten** files (size + modified date), finished after 45 s with no change |
| `Settings*.swift` | Tabs: Team, Modhesh, Folders, General |
| `SheetSync.swift`, `SheetService.swift`, `GoogleSheet/` | Old Google Sheet logging. **Switched off** (`Features.sheet = false`), kept on purpose |

## Supabase
- Project URL and **anon key** are in `Cloud.swift` and `ChromeExtension/tasktimer.js`. The
  anon key is public by design; Row Level Security protects the data.
- `Supabase/schema.sql` is the whole schema, written so it's **safe to run again**. When you
  add a column, add it there with `add column if not exists` and tell the other person to run
  the file in SQL Editor → New query. Code that reads new columns must still work when the
  column isn't there yet (see the push fallback in `CloudSync`).
- Roles: `profiles.role` is `member`, `leader` or `admin` (Hosam's call: **an admin is only an
  admin** — never in a team, no tasks of their own, not a leader; the app doesn't sync an
  admin's local tasks). `profiles.is_admin` is kept equal to `role = 'admin'` for older app
  builds; `is_admin()` in SQL checks the role. Admins can read every profile, team and task
  (RLS). Nobody can make themselves admin (users can only update `full_name`); only admins
  can, through the Edge Function, and there must always be at least one admin. The first
  admin is set by hand in SQL.
- Deleting an account (admin) deletes the sign-in, profile and **all their tasks** (cascade),
  so their hours leave team history too. Taking someone out of a team keeps everything.
- Accounts blocked by old versions (`auth.users.banned_until`) show as "Blocked" in Admin →
  People, with Unblock; resetting a password also unblocks.
- Members only see their own data. Leaders see their team's tasks and can insert `incoming`
  tasks for teammates, but can't edit anyone's hours.
- A task's `team_id` and `owner_name` are fixed at insert by a trigger. Removing someone
  from a team keeps their history with the old team.
- Edge Function `Supabase/functions/team-admin` holds the
  **service_role key server-side**. Leader actions: `create`, `add_existing`, `reset`,
  `remove` (own team only). Admin actions start with `admin_` (`admin_list`,
  `admin_create_user`, `admin_update_user`, `admin_reset`, `admin_unban`, `admin_delete_user`,
  `admin_create_team`, `admin_rename_team`, `admin_delete_team`). Emails are checked on both sides with the
  same pattern (`name@domain.tld`). **After changing the function, it has to be deployed
  again in Supabase**: Edge Functions → team-admin → Code → paste → Deploy. Never put the service_role key, the DB password or the DB
  URL in the code, in chat, or in this public repo.
- Free tier budget: about 40 users and 1000+ tasks a month have to fit in 5 GB of egress a month.
  Keep polling slow and queries incremental and filtered (select only the needed columns,
  `updated_at=gt.`). Current timers: sync every 120 s; Modhesh links every 3rd tick; weekly
  report and settings every 5th; team window every 60 s while open.
- Backups (planned): nightly `pg_dump` via GitHub Actions into a **private** repo
  (`tasktimer-backup`, secret `SUPABASE_DB_URL`). Never in this repo, because it's public.

## Chrome extension (ChromeExtension/, MV3)
- `background.js` is the **only** place that reads Modhesh (`readModhesh`): one path, with the
  owner check. Don't add page-side uploads again (that once fought with the owner check and
  dropped every task). `content.js` only asks the background (`readNow`) and runs the jobs.
- Modhesh `/tasks/my?...start_month=&start_year=` returns JSON whose `columns` are keyed
  by status: 1 Pending to Start, 6 In Progress, 4 Completed, 5 Pending Approver, 2 Rejected.
  The app shows only statuses 1 and 6.
- **Owner check:** tasks are taken only when the Modhesh name matches the TaskTimer name,
  or when the user confirmed it ("It's me"). The status of the last read is written to
  `user_settings.modhesh_status` and shown in the app.
- **Linking is manual only.** Automatic linking by name was removed because it linked the
  wrong tasks. Don't bring it back.
- When a **linked** task is Completed in TaskTimer, the extension:
  1. If the Modhesh task is Pending, sets status In Progress plus Start Date from the app on
     Task Details (`#updaterequest`). It leaves the Estimate and the deliverables link alone.
  2. Fills Log Time (`#add_members`): hours/mins, deliverables, stars, challenge (default
     1 = "No Challenges at all"), Complete, approver = the team leader. Then Save.
  "Save, keep In Progress" in Done does **not** send.
- Defaults: 5 stars, 1 deliverable, challenge 1. They're per user in Settings → Modhesh
  (`user_settings`).
- Bump `manifest.json` version when the extension changes: the installed copy reloads
  itself when the version on disk changes.

## After Effects import
- Everything goes in **one** `DoScript` call, plain files first and PSD/AI last. AE may open
  its own PSD import window, and a second script while that window is open fails with
  "Cannot run a script while a modal dialog is waiting".
- Only items created by the import are moved into the project folder. Existing items are
  never touched; a name clash gets " (new)" added; a file already in the project is skipped.
- Layer styles (Editable/Merge) can't be set from scripting.
- Render Queue output (AERenderHelper): a project counts as a task's when the .aep is in
  `Task/<AE folder>/` or `Task/` and `Task/` has a Render / Renders / Output subfolder. Only
  newly added queue items are changed (plus, on first open, queued items pointing outside the
  task folder). Never poll AE with DoScript from TaskTimer: a DoScript while AE shows a
  window makes AE show an error; the helper runs inside AE instead.

## User-facing text
- UI text is English. Hosam talks in Egyptian Arabic; reply to him in Arabic.
