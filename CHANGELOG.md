# TaskTimer changelog

Newest first. The top section becomes the release notes shown in the app.

## 1.15.2
- "Add Extension" disappears as soon as the extension is in Chrome (TaskTimer checks Chrome itself — no waiting). Signing in to the extension connects it right away.

## 1.15.1
- Add Extension now really opens Chrome's extensions page (macOS asks once to let TaskTimer control Chrome — press OK). If it can't, the address is copied so you can paste it.

## 1.15
- Settings → Modhesh: default stars, deliverables and challenge answer, the automatic link / log switches, and the extension's status.
- The Chrome extension now comes inside TaskTimer. "Add Extension" opens Chrome's extensions page and the extension folder, with step-by-step help. After that it updates itself whenever TaskTimer updates.
- The Modhesh window shows "Add Extension" until the extension is connected.
- The main window fits any width: buttons turn into icons and the filters wrap when the window is narrow.
- Run the latest schema.sql once (adds the settings table).

## 1.14.1
- Chrome extension 2.1: a finished task that is still "Pending to Start" on Modhesh is moved to In Progress first (only the status and the Start Date — from when you started it in TaskTimer — are changed), then its time is logged and sent to your approver.

## 1.14
- Modhesh, hands-off: the Chrome extension (2.0) reads your Modhesh tasks every 5 minutes without opening Modhesh, links them to TaskTimer tasks with the same (or clearly matching) name, and when a linked task is Done in TaskTimer it logs the time on Modhesh by itself and sends it to your team leader for approval. The same hours are never sent twice.
- New Modhesh tasks: TaskTimer sends a notification and the Modhesh button lights up.
- Link a Modhesh task to an amend: "All tasks and amends" in the link menu.
- The Modhesh window shows what was sent to the approver and when.
- Run the latest schema.sql once (adds the sent-to-approver columns).

## 1.13.1
- Chrome extension 1.2: Log Time opens with "No Challenges at all" ticked; tick something else if needed.

## 1.13
- Each account keeps its own tasks: two people signing in on the same Mac no longer see (or send) each other's tasks.
- Signing in on a new Mac brings your tasks back from your account.

## 1.12
- Modhesh window shows only tasks that are Pending to Start or In Progress.
- Chrome extension 1.1: a link made in the app shows up on Modhesh within seconds — the Log Time bar switches to "Fill from TaskTimer" by itself, and linked cards on the board get a TaskTimer badge with the hours.
- The extension now says so when it can't find any TaskTimer tasks for the account.

## 1.11
- Modhesh: a new Modhesh window links each Modhesh task to the TaskTimer task you timed (best match suggested), or adds it to Incoming.
- New Chrome extension (TaskTimer-Chrome.zip in the release) fills Modhesh's Log Time — hours not yet logged, deliverables, stars, challenges, complete + your team leader as approver — and the Start Date. You press Save.
- Run the latest schema.sql in Supabase once (adds the Modhesh table and the start date).

## 1.10
- Done asks for Deliverables and stars (how happy you were with the task). Defaults: 1 deliverable, 5 stars — change them in Settings → General.
- Both go to the team database (and the leader's CSV), ready for Modhesh's Log Time.

## 1.9
- Render notifications: when a render lands in a task's Render folder, you get a notification with Stop timer / Stop & Done.
- Team → Summary: hours and tasks by account and by member, for the month, this week or last week, with Copy Report.
- Weekly report: every Monday from 9:00 the team leader gets last week's numbers as a notification; clicking it opens the summary.

## 1.8.1
- Menu bar timer is shorter (1:05) so macOS doesn't hide it when the bar is full. Settings → General lets you pick 1:05, 01:05:12 or icon only.

## 1.8
- Removing someone from a team keeps their account and their past tasks; another team leader can then add them (Add Member with their email).
- A leader still sees who did old tasks after that person leaves.

## 1.7
- Incoming tasks get their folder when you press Start (in that month's folder), not when they are added. Tasks from your leader too.
- The AE template path is no longer filled in with someone else's path; it only shows an example.
- Fixed: two requests renewing the sign-in at the same moment could sign you out.

## 1.6
- Accounts are created by the team leader (Team → Add Member); members only sign in.
- Members can change their password in Settings → Team.
- Leaders can reset a member's password or remove them from the team (right-click their card).

## 1.5
- Team accounts: sign in from Settings → Team. Your tasks are copied to the team database.
- Team leaders get a Team window: who is working on what right now (live timers), every task by month, member and status, and export to CSV.
- Leaders can assign a task; it lands in the member's Incoming.

## 1.4
- No more Google Sheet: everything stays in the app (the sheet code is kept aside, switched off).
- Incoming: add a task now and press Start later. Incoming → In Progress → Completed.
- Done asks for the hours (3, 3.5 …) and the day.
- Month filter: show the tasks created in a month.
- Task folders can go into the client's folder or one folder of months (Client / Oct 2026 / Task). A missing month folder is created, named like the others.

## 1.3.1
- Fixed: Update could stay on "Installing…" when a window like Settings was open.

## 1.3
- Reads the team sheet: accounts, status words and team members come from the sheet's dropdowns. Press Sync from Sheet after anything changes there.
- Picks this month's tab by itself (or a tab you choose in Settings → Sheet).
- Amends: add subtasks under a task, each with its own timer and its own row ("Task - Amend 1").
- Needs the new TaskTimer.gs pasted into the sheet's Apps Script once.

## 1.2
- Updates now come straight from GitHub: when a new version is published, TaskTimer shows an Update button and installs it in place.
- No Command Line Tools needed for updates any more; the app arrives ready-built and runs on Apple Silicon and Intel Macs.
- New task folders are created even if the After Effects template isn't found on this Mac.

## 1.1
- In-app updates from a downloaded zip.
- New folder tree: 06 - Images, 07 - Videos, 08 - Others. Dropped files are sorted by type (PSD/AI/EPS → PSD, images → Images, video → Videos, everything else → Others).

## 1.0
- First version: task timer, task folders from the AE template, clients list, logging to the team Google Sheet.
