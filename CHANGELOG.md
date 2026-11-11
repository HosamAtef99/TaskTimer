# TaskTimer changelog

Newest first. The top section becomes the release notes shown in the app.

## 1.33
- Team leaders: the Modhesh window shows the tasks waiting for your approval on Modhesh, with Approve, Approve All and Return (with a reason). It's done in your Chrome by the extension, so Chrome has to be open and signed in to your Modhesh.

## 1.32.3
- Imports into After Effects really try again now: when After Effects says "Cannot run a script while a modal dialog is waiting", Mongez waits until you close that message (and any other After Effects window) and sends the import again, up to 3 more times.
- Admin → Hours: an amend shows its task's name ("Task - Amend 1").

## 1.32.2
- Groups show folded: just the group's card. Click it to see its tasks.

## 1.32.1
- Grouping is quicker: press the ✓ button next to the filters (or right-click a task → Select), click the tasks you want, then New Group or Add to Group from the bar at the bottom. The same bar can take tasks out of their group.

## 1.32
- **Render Queue → the task's Render folder by itself again**: anything you add to the Render Queue in a task's project gets the task's Render folder and the next name (Task_v01, Task_v02…), and it stays that way when you open another project and come back. No button needed (Settings → Folders to turn it off). Mongez puts a small helper into After Effects once each time it starts; it only looks at the Render Queue.
- Imports into After Effects don't get lost any more: when After Effects has a window or menu open, Mongez waits for it to close instead of getting "Cannot run a script while a modal dialog is waiting", and tries again if After Effects still says so.
- **Groups**: put several tasks (an event's, say) in a group — right-click a task → Add to Group → New Group… The group's tasks show inside its card. Link the group to one Modhesh task and press Done on the group: the hours of all its tasks go there together.
- Linking a Modhesh task: picking a task opens a card with its last render (and its hours), so you can check it's the right one before you press Confirm Link.
- Right-click a task → **Mark as Linked to Modhesh** for work you entered on Modhesh yourself: it counts as closed there, and the extension never sends it.
- The month filter starts on this month.
- Admin → Clients: add many clients or pitches at once, one per line.

## 1.31.2
- Hours line up: completed hours always show as 00.0 h (01.0, 02.5, 15.5), so the buttons beside them sit in one line, row under row.
- Hover any task tool (Open AE Project, Set Render Outputs, Organize, Collect, folders) to see its name. The folder button is centred like the others.
- In a narrow window, the tools button opens a panel with every tool and its name, in a grid.
- The same room above the top bar as at the bottom of the window.
- Set Render Outputs saves the After Effects project after setting the paths, so they stay the same when you open another project and come back.

## 1.31.1
- Nothing goes out of the window any more: Settings and the other windows fit inside Mongez's window, and scroll when they're too long, so their title and Done button always show.
- More room around the edges of the main window, so the buttons at the top don't touch the edge.
- In a narrow window, a task's After Effects tools fold into one button (press it for the menu), and the line under the name drops the date or status instead of cutting the row.

## 1.31
- **A calmer look ("Mist")**: the same teal and coral, much softer, in light and dark.
- The main button of each screen (New Task, Done, Complete, Assign Task…) stands out with a soft gradient and dark text. Hover over it and a ring of light turns behind it; click it and a wave spreads out. The other buttons stay quiet and light up a little on hover.
- The window can't get narrower than 600 px any more, so text no longer runs into other text.

## 1.30
- **TaskTimer is now Mongez**: new name, new logo and a new look — teal and coral frosted glass, in light or dark (Settings → General → Appearance). The app installs itself as Mongez.app.
- The running task sits in its own card with its amends (press one to switch the timer), its After Effects tools and Done. Drop files on the card to add them to the task.
- Status tabs, search, month and Modhesh filters are together above the list, and task names show in full.
- Every task has small buttons for Open AE Project, Set Render Outputs, Organize, Collect and its folders. Check Render Folder… is in the task's right-click menu.
- Organize puts every comp that was rendered (Done in the Render Queue) into a "Main Comps" folder. Collect organizes the project first when it's open in After Effects (turn it off in Settings → Folders).
- Clients come from the admin only: Admin → Clients adds each team's clients and pitches. You pick from your team's list; there's no "add client" any more.
- Support: in New Task and Done, tick Support to search every other team's clients when you're helping another team.
- Pitches: the admin adds a pitch to the team that handles it; it shows under Pitches in New Task.
- Done has "Approver on Modhesh": your team leader is picked for you (the other team's leader for support), and you can choose any leader.
- The day you pick at Done becomes the Modhesh task's Start Date when the extension logs it.
- The Chrome extension only reads Modhesh when you press Check now.
- Importing a task folder asks for its name and client, and guesses the client from where the folder is.
- Task folders are the same for everyone, and each new task gets an empty After Effects project: pick your After Effects version (2024, 2025 or 2026) in Settings → Folders.
- Auto-import downloads is gone. Dropping files on a task still asks whether to import them into After Effects.
- Admin → Teams → Start Fresh deletes every task so the team can start clean.

## 1.29
- Task folder menu → Set Render Outputs: puts everything queued in the Render Queue into the task's Render folder, named Task_v01, Task_v02… (never overwriting an older render). It runs only when you press it — nothing checks After Effects in the background.

## 1.28
- Removed TaskTimer's helper from After Effects: renders are no longer redirected to the task's Render folder or renamed, and nothing checks After Effects in the background any more. The helper is taken off your Mac automatically. Render-finished notifications and the last-render picture still work (they only look at the task's Render folder).

## 1.27
- Removed: the timer no longer switches tasks by itself when you open another task's After Effects project.
- TaskTimer's helper in After Effects now only looks at the Render Queue (every 5 s), and only while "renders to the task's Render folder" is on.

## 1.26.1
- If TaskTimer's helper doesn't start by itself in After Effects, open Window → Extensions → TaskTimer Helper once and dock the small panel anywhere; it shows whether it's connected.

## 1.26
- No more "Cannot run a script while a modal dialog is waiting for response" in After Effects: TaskTimer now works through a small signed helper inside After Effects that waits for After Effects' own windows to close. **Quit and reopen After Effects once** after updating so it loads.
- The timer following the open project no longer needs After Effects' "Allow Scripts to Write Files" setting.

## 1.25.1
- Opening another task's After Effects project now pauses the timer that's running (even one you started by hand) and starts the new task's timer.
- Settings → General shows what TaskTimer sees in After Effects (connected or not, which project is open, which task it belongs to), with a Connect now button.

## 1.25
- Auto-import downloads (the ⬇︎ button in the header, or Settings → General): while it's on, anything that finishes downloading goes straight into the running task's folder (Images, Videos, Sound…) and into the project open in After Effects. Turn it off with the same button.

## 1.24.3
- The last-render picture on the task card fits its height, so the whole frame shows (vertical renders too).
- Bigger text in the email and password fields.

## 1.24.2
- When a task folder has several After Effects projects, Collect, Organize and Open AE Project use the most recently saved one (After Effects' Auto-Save copies and collected copies don't count).

## 1.24.1
- Collect puts the footage in the same folders as in the After Effects project panel (like After Effects' own Collect Files), not by where the files were on the Mac.

## 1.24
- Collect AE Project works properly now: it copies every footage file the project uses into Collect/<Task> <date>/(Footage) (same subfolders as in the task folder) and points the collected project to them — PSD and AI layers included. It doesn't need After Effects at all, and the collected folder also opens on another Mac. A report lists what was collected and what's missing.

## 1.23.2
- Render notifications also come for tasks you marked Done (timed in the last 3 days) and for Incoming tasks.
- The last-render picture on the task card shows again.

## 1.23.1
- Collect AE Project works with After Effects closed: TaskTimer starts it hidden in the background, collects, and quits it again.
- Task folder menu → Check Render Folder…: shows why a render notification or the last-render picture doesn't show (folder, Render folder, permissions, notifications).

## 1.23
- Timer follows After Effects: opening a task's project starts its timer, closing it (or opening another task's project) pauses it. Turn on "Allow Scripts to Write Files and Access Network" in After Effects once (Settings → Scripting & Expressions).
- Renders are named Task_v01, Task_v02… in the task's Render folder, so a render never overwrites an older one.
- Task folder menu → Organize AE Project: sorts the project panel into Comps, Precomps, Footage, Images, PSD & AI, Audio, Solids.
- Task folder menu → Collect AE Project: copies the project and all its footage into the task's Collect folder.
- The task card shows a small picture of the last render; click it to open it.

## 1.22
- Admin is its own role now: an admin isn't in a team and doesn't time tasks. Signing in as an admin opens the Admin panel as the main window.
- Admin → Hours: every team's hours for a month, each person's hours, tasks done and in progress, who's working now (and on what), each person's task list, CSV export.
- Admin → People: delete an account for good, unblock accounts blocked by older versions, flags emails that look wrong.
- Run the latest schema.sql once, and deploy the new team-admin function.

## 1.21
- After Effects renders go to the task's Render folder: a comp added to the Render Queue in a task's project gets its output set to that task's Render folder (Settings → General, on by default). Changing the output by hand afterwards is kept.

## 1.20
- Admin window (shield button, admins only): every account and team in one place. Add leaders and members to any team, move people between teams, make someone a leader or member or admin, reset passwords, create / rename / delete teams.
- Leaders: "Add Member" can now add an existing account by email (someone removed from another team), and emails are checked (name@company.com).
- Dropping files on a task asks: Move or Copy, and (when After Effects is open) whether to import them, in one window.
- Render notifications also work when a render overwrites an existing file, and while only an amend is in progress.
- Run the latest schema.sql once, and deploy the new team-admin function.

## 1.19.3
- The main window fits again when it's made narrow (filters go on separate rows).
- After Effects import never changes what's already in the project; a file already imported is skipped.

## 1.19.2
- After Effects import runs as one script, PSDs last, so After Effects' own PSD window doesn't block the other files.

## 1.19.1
- Choose how PSD / AI files come into After Effects (Composition - Retain Layer Sizes, Composition, Footage).

## 1.19
- Modhesh filter: Closed on Modhesh / Not closed yet / Not linked.
- Drop files on a task: they're sorted into its folders, then you're asked whether to import them into the After Effects project that's open.

## 1.18.2
- Fixed: Modhesh tasks could be taken and then removed again (an old part of the extension skipped the "whose Modhesh is this" check). Extension 2.6 reads Modhesh in one place only.
- Settings → Modhesh and the Modhesh window show what the last read found ("13 tasks read from Modhesh (Hossam Atef) · 3 pending or in progress", or why nothing was taken).
- Run the latest schema.sql once.

## 1.18.1
- Modhesh window: "Clear & re-check" removes every Modhesh task there that wasn't sent yet and reads your Modhesh again from scratch.

## 1.18
- Modhesh tasks now belong to the right person: the extension only takes tasks from the Modhesh account that matches your TaskTimer name (or that you confirm with "It's me" in Settings → Modhesh). Tasks picked up from someone else's Modhesh are removed.
- Signing out clears everything Modhesh-related from the app, so the next account starts clean.
- Automatic linking by name is gone (it linked wrong tasks). Links it made that weren't sent yet are undone; link tasks yourself from the Modhesh window.
- Run the latest schema.sql once.

## 1.17.1
- Tasks linked to Modhesh have a green "Modhesh" tag in the lists, and "Modhesh ✓" once their time was sent there.

## 1.17
- The timer card shows this month: tasks completed and their hours. It changes when you complete a task, not with the running timer.
- Pause and Done in the timer card are icons now (⌘⇧P / ⌘↩ still work).

## 1.16.2
- Chrome extension 2.4.1: name matching looks at the last 3 weeks of tasks only (even lighter on the database).

## 1.16.1
- Much lighter on the team database (to stay inside the free plan with the whole team): syncing every 2 minutes, only Modhesh tasks that still need work, the Team window downloads only what changed, and the Chrome extension (2.4) only reads the tasks it needs.

## 1.16
- Done: the time is now big and simple — hours and minutes, filled in to the nearest half hour, with − / + half-hour buttons.
- Done asks "Did you face any challenges?" (your default from Settings → Modhesh is pre-picked); the answer is used on Modhesh.
- Task cards no longer wrap the date or the Done button when the window is narrow.
- Run the latest schema.sql once (adds the challenge column).

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
