# Admin (Chat Report Center)

Lives in `admin/` inside the chat application folder. It is the owner's app for the chat application (website + phone app).
It does **not** touch the chat application: it only reads its database
(connection is read-only) and keeps its own settings in `data/report.db`.

## Run
Double-click **start.bat**, or:

    venv\Scripts\python.exe server.py

Open http://localhost:4700 . First visit: choose a password.
(Or put `ADMIN_PASSWORD=...` in `.env`.)

## Pages
- **Overview** – total users, online now, active today/week/month, new sign-ups, health.
- **Users** – searchable list (name, email, mobile, joined, last seen, device) + CSV download.
- **Reports** – messages, calls, AI use, sign-up emails, phone vs website, disk, backups;
  daily CSV (90 days), "Email me this report", print/PDF.
- **Email** – sender Gmail + app password, owner email, test email, `.env` lines to copy.
- **AI & Voice** – AI key (OpenAI-compatible / Claude / Gemini), "Hey ARM" reply style, try-it box.
- **App name & logo** – the name and logo you set here show on every page of the chat app
  (sign-in, lock screen, browser tab, phone install icon) and on this admin page.
  Saved in `storage/branding/`, which the chat API serves.
- **System** – uptime, activity log, change password.

## Notes
- Message text is end-to-end encrypted; reports only count messages.
- Settings (app password, AI key) are saved in `data/report.db` on this PC and shown
  only as the last 4 characters. Don't share the `data` folder.
- `.env` holds the chat database login (copied from the chat backend's `.env`).
- To let other devices open it, set `HOST=0.0.0.0` in `.env`.
