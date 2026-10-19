# TaskTimer changelog

Newest first. The top section becomes the release notes shown in the app.

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
