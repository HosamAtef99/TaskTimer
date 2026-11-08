# TaskTimer Dev — notes for Claude (and people)

Read this before changing anything. Hosam and Mousab both work on this repo, each with
their own Claude. This file is how decisions made in one person's chats reach the other.
When you make a decision that the other person would need to know, add it here.

## What this is
- **Mongez** (منجز; called TaskTimer Dev until 1.30, Hosam's call): macOS menu-bar + window time
  tracker for an animation team (bundle id still `com.hosam.tasktimer.dev`; the Application
  Support folder is still `TaskTimer Dev`, the release zip is still `TaskTimer.app.zip`, and the
  updater installs it as `Mongez.app`, replacing `TaskTimer Dev.app`; the Chrome extension is still
  "TaskTimer for Modhesh"). It's Hosam's test fork of
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
- Pushes that don't change VERSION upload the build to the **`dev-build` pre-release** (Hosam's
  call), for testing with Settings → General → Install from File…. The updater never offers it.

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
| `FolderService.swift` / `MonthFolder.swift` | **Fixed folder tree** (`Pref.subfolderList` = `Pref.defaultSubfolders`; nobody edits folder names any more, Hosam's call) and **no AE template choice**: `createProject` copies the empty `Resources/Blank-<24|25|26>.aep` (Hosam's files, one per AE version; `Pref.aeVersion`, Settings → Folders, default = newest AE in /Applications) as `<Task>.aep` into "01 - AE". `aeFile(in:)` = the task's AE project: newest .aep/.aepx anywhere in the task folder (3 levels; skips Auto-Save, Collect and Render folders) — used by Open AE Project, Organize and Collect. Task folders (client folder or months root; the month folder name copies the style of the existing ones). Dropped files are sorted into subfolders by type, moved or copied (the user picks in `DropFilesSheet`, in `MainView.swift`) |
| `AfterEffects.swift` | Imports dropped files into the open AE project through AppleScript `DoScript` |
| `AEHelperRemoval.swift` | **No helper inside After Effects any more** (Hosam's call, 1.28): the Render Queue → Render folder / `_v01` naming and the timer following the open project were removed, and nothing checks AE in the background. On launch this deletes the old "TaskTimer Helper" CEP extension (`~/Library/Application Support/Adobe/CEP/extensions/com.tasktimer.aehelper`) and its files. Don't bring a background AE poller back without asking |
| `AEProjectTools.swift` | Task row and NowCard (Hosam's call, 1.30): `TaskTools` in `MainView.swift` = small round icons for **Open AE Project**, **Set Render Outputs**, **Organize**, **Collect** and a folder menu with only Open Project Folder / Open Render Folder. "Check Render Folder…" is in the row's right-click menu. **Collect organizes first** (Settings → Folders → "Organize the AE project before Collect", `Pref.organizeBeforeCollect`, on by default; Hosam's call): if the task's project is the one open in AE, the Organize script runs and saves, then the file is collected; a project that isn't open is collected as is (AE isn't opened for it). **Set Render Outputs** (`renderToTask`, only when pressed — Hosam wants **nothing** checking AE in the background; he tried an automatic version in 1.30 and dropped it the same day: queued Render Queue items of the task's open project → the task's Render folder, named `<Task folder>_v01…`, next free number in the folder + queue; already-correct items left alone), **Organize AE Project** (every comp the Render Queue shows as Done goes to a "Main Comps" folder, wherever it was — Hosam's call; then loose items into numbered bins; one undo step) and **Collect AE Project** — done **without After Effects** by `AEPFile.swift`, which reads/rewrites the .aep (RIFX) directly: footage paths are the `alas` JSON records inside `LIST:"Pin "` (render outputs are under `LIST:"LOm "` and are left alone). Copies go to `<Task>/Collect/<Task> <date>/(Footage)/<the item's project-panel folders>/` like AE's own Collect (Hosam's call: organized as in After Effects, not by where the file sits on disk; folders come from `LIST:Item` → `idta` type 1 + `Utf8` name → `LIST:Sfdr`), the copy's records get the new `fullpath` and AE's relative-path counts (`ascendcount_base/target`), the result is read back before it's written, plus a `<Project> Report.txt`. PSD/AI layers keep their layer. If AE has the project open with unsaved changes it's saved first. Unchanged chunks are written byte for byte (`Tests/AEPFileTest`, run in CI before the build, checks round trips). Format reference: forticheprod/aep_parser `docs/file_format.md`. `collectWithAE` (old way, through AE scripting; starts AE hidden if needed) is only the fallback for project files `AEPFile` can't read. "Check Render Folder…" (`RenderWatcher.diagnose`) explains why notifications / thumbnails don't show. Also `RenderThumb`: newest render's thumbnail on the task row (QuickLook, checked every 60 s) |
| `Cloud.swift` / `CloudSync.swift` | Supabase auth + REST, push/pull, team, Modhesh state, weekly report |
| `TeamView.swift` | Leader window: tasks, summary, add member (new account, or an existing account by email), reset/remove member, assign task, CSV. `isValidEmail` / `EmailHint` live here |
| `AdminView.swift` | Admin panel — the **main window for admin accounts** (`AdminView(embedded: true)` in `MainView`). Tabs: Hours (every team's and person's hours / done / in progress / working now for a month, per-person task list, CSV), People (move between teams, set role, reset password, unblock, delete account for good), Teams (create / rename / delete empty) |
| Import folder (`ImportFolderSheet` in `MainView.swift`, `Store.importFolder` / `guessClient`) | Asks for the task name and client (with Support). The client is guessed from the folder's `.tasktimer.json`, then the client whose folder holds it, then a parent folder named like a client; a guessed client of another team turns Support on. Never creates local clients when the admin's list is in use |
| `ModheshView.swift` | Link Modhesh tasks to TaskTimer tasks or amends (manual only) |
| Clients (`Store.applyCloudClients`, `CloudSync.loadClients`, `ClientPicker` in `Sheets.swift`, Admin → Clients) | **Only admins add clients and pitches** (table `clients`: name, team, kind `client`/`pitch`, active). Everyone reads the list; the app merges it into the local `clients` (a local client with the same name becomes the cloud one and keeps its folder; old names stay for old tasks, never pickable). New Task / Done: my team's clients, then my team's open pitches; the **Support** toggle searches every other team's clients instead (`TaskItem.support`). Pitches have no life cycle (Hosam's call): added to a team, shown under Pitches, deleted by the admin when done. Admin → Clients shows hours per client / pitch per month and old names not in the list |
| Approver (`DoneSheet`, `CloudSync.leaders` / `defaultApprover`) | Done has "Approver on Modhesh": all leaders from the SQL function `leaders()`; default = leader of the client's team (so support goes to the other team's leader), else my leader. Saved on the task (`approver_id`, `approver_name`); the extension picks that name in Log Time, or the team leader when empty |
| `ExtensionInstaller.swift` | Copies the bundled extension to `~/Library/Application Support/TaskTimer Dev/…`, opens `chrome://extensions` through AppleScript, detects the installed extension from Chrome's prefs |
| `RenderWatcher.swift` | "Render finished" notification with Stop/Done. Watches a task's Render folder while the task or an amend is in progress / Incoming / timing, or was timed in the last 3 days (`RenderWatcher.watched`); new **or overwritten** files (size + modified date), finished after 45 s with no change |
| `TestCopies.swift` | **Temporary** (Hosam's call): Settings → General → Open Test Copy 2 / 3 copies the app to `~/Applications/Mongez Test N.app` with bundle id `com.hosam.tasktimer.dev.testN` (own UserDefaults), re-signs it ad hoc and opens it, so admin, leader and member can be signed in at once. `TestCopies.supportDir` (`TaskTimer Dev Test N` in Application Support) holds a copy's session and data; copies don't run the updater or install the Chrome extension. Remove when no longer needed |
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
- **Start Fresh** (Admin → Teams): SQL `admin_start_fresh()` deletes every task and Modhesh link,
  sets every `user_settings.modhesh_reset_at` (the extension forgets what it sent) and writes
  `app_settings.data_reset_at`. Each app (`CloudSync.applyFreshStart`, at start and every tick)
  drops local tasks created before it, after copying its data file to `…-before-fresh-start-<day>.json`.
- Backups (planned): nightly `pg_dump` via GitHub Actions into a **private** repo
  (`tasktimer-backup`, secret `SUPABASE_DB_URL`). Never in this repo, because it's public.

## Chrome extension (ChromeExtension/, MV3)
- `background.js` is the **only** place that reads Modhesh (`readModhesh`): one path, with the
  owner check. Don't add page-side uploads again (that once fought with the owner check and
  dropped every task). `content.js` runs the logging jobs (and sets the Start Date); `readNow` comes
  only from the popup's Check now.
- **Modhesh is read only when the person presses "Check now"** in the extension popup (Hosam's call):
  no 5-minute alarm, no read when a Modhesh page opens. The 2-minute `tick` stays: it reads only
  TaskTimer's database and logs finished linked tasks (off with Settings → Modhesh → automatic).
- **Start Date:** the day picked at Done (`tasks.work_date`) becomes the Modhesh task's Start Date:
  before Log Time, `prepareInModhesh` opens Task Details and sets Start Date (and In Progress if it
  was Pending), then Update Task; nothing is saved when both already match.
- Modhesh `/tasks/my?...start_month=&start_year=` returns JSON whose `columns` are keyed
  by status: 1 Pending to Start, 6 In Progress, 4 Completed, 5 Pending Approver, 2 Rejected.
  The app shows only statuses 1 and 6.
- **Owner check:** tasks are taken only when the Modhesh name matches the TaskTimer name,
  or when the user confirmed it ("It's me"). The status of the last read is written to
  `user_settings.modhesh_status` and shown in the app.
- **Linking is manual only.** Automatic linking by name was removed because it linked the
  wrong tasks. Don't bring it back.
- When a **linked** task is Completed in TaskTimer, the extension:
  1. On Task Details (`#updaterequest`): Start Date = the Done day, status In Progress if it was
     Pending. Estimate and the deliverables link stay as they are.
  2. Fills Log Time (`#add_members`): hours/mins, deliverables, stars, challenge (default
     1 = "No Challenges at all"), Complete, approver = the one picked at Done (`approver_name`),
     or the team leader. Then Save.
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
- Nothing in TaskTimer checks After Effects on a timer. **Auto-import downloads was removed in
  1.30** (Hosam's call: it sent imports to AE in the background and clashed with his other
  scripts); the drop sheet's "Import into After Effects" checkbox stays. Versions 1.21–1.27 left
  `app.scheduleTask` / the CEP helper running inside AE until AE restarts.
- TaskTimer only talks to AE (AppleScript `DoScript`) when the person does something: an import
  (drop), Set Render Outputs, Organize, the save before Collect. A DoScript while AE shows
  one of its own windows makes AE show "Cannot run a script while a modal dialog is waiting".

## Look ("Mist", after 1.30: Mousab's design, Hosam approved it)
- Liquid-Glass style, **teal + coral, softened** ("Mist"), light and dark (Settings → General →
  Appearance: System / Light / Dark, `Appearance.apply()` sets `NSApp.appearance`). `Theme.swift`:
  `teal`, `coral`, `ink`, `pitch`, `support`, `slate` are dynamic colours; the old names (`blue`,
  `purple`, `pink`…) map onto them. Glass = `.ultraThinMaterial` + white edge (`glassCard`,
  `glassChip`); macOS 26's real `glassEffect` isn't used (CI SDK, macOS 13 support).
- **Loud vs quiet buttons.** Only the main action of a screen is loud: `GradientButtonStyle` (soft
  coral gradient `Theme.coralFill`) and `CircleIconButtonStyle(filled: true)` (soft teal
  `Theme.tealFill`: play / pause, + 30 min), with **near-black text** (`Theme.buttonInk`, never
  white). Everything else is quiet: `GlassButtonStyle` / unfilled circles = a glass chip that
  brightens on hover. Loud ones: New Task, Done, Complete, Create & Start, Assign Task, Add Account.
- **Button motion** (`LoudButtonLook` in `Theme.swift`): on hover a gradient ring of light
  (`Theme.ring`, teal → blue → coral → amber) turns behind the button, drawn with a `TimelineView`
  only while the pointer is on it (nothing animates in the background); on press the button sinks,
  the glow flares and a gradient wave spreads from behind it.
- The main window is never narrower than **600 px** (was 470; text ran into other text).
- **Nothing may touch or leave the frame** (Mousab's call, 1.31): the main window keeps a safe
  margin all round (18–24 pt sides, room above the top bar) so buttons and their glow stay inside.
  `MainView` passes its size down as `\.mainWindowSize`. **Sheets are never taller than the main
  window** (`Room.sheetHeight`): `SheetFrame` scrolls its content when it doesn't fit; sheets that
  scroll inside themselves and set their own size (Settings, Team, Clients, Modhesh, Admin) pass
  `scrolls: false` and cap their height with `Room.sheetHeight`. Task rows follow the window
  width: ≥ 900 tools + render picture, ≥ 760 tools, narrower = all tools folded into one button
  (`TaskTools(grouped: true)`, a menu). The line under a task's name drops the date, then the
  status, then the tag when it doesn't fit, and long client names are shortened, so a row is
  never wider than the window.
- Logo: stopwatch whose hand is a check mark, stroke only (`MongezLogoShape` in `MainView.swift`,
  also the menu bar template icon `MenuBarIcon` and `Resources/AppIcon.iconset`).
- Main window, top to bottom: one bar with the window buttons, logo, Modhesh / Team / Clients /
  Import / Settings and New Task; Today · This week · Done this month; **NowCard** (running task:
  amends as chips you press to switch the timer, + Amend, AE tools as small icons with tooltips,
  clock teal→coral, Done; files can be dropped on it); then status tabs with counts + search +
  month + Modhesh filter; then the task rows (whole name on up to 2 lines, Support / Pitch tags,
  `TaskTools` icons). The newest render's thumbnail (`RenderThumb`) shows on the task rows, not on the NowCard (Hosam's call).

## User-facing text
- UI text is English. Hosam talks in Egyptian Arabic; reply to him in Arabic.
