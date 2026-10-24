# DI-VERSE local SQL admin platform

## Start the app

1. Double-click `start-local.bat`. On first run, the server creates the `DIVerseAccounts` database and its tables in this Windows user's SQL Server LocalDB instance.
2. Keep the PowerShell window open. The app opens at `http://127.0.0.1:8765/`. Do not open `index.html` directly as a file; the local server is required for authentication and database access.
3. The owner admin account is provisioned automatically on first run. Open **Admin access** and sign in with the allowlisted owner email and the configured admin password. No setup code is required.
4. Use the sign-up form to add accounts, then sign in to reach the authenticated homepage and open the DI-VERSE community.
5. Close the server window or press Ctrl+C when finished.

## Community pages

The signed-in community contains a profile editor, friend search and requests, friend-only direct messages, shared posts, a PDF library (10 MB maximum per file), business/job/skill/product listings, and a movie library for MP4/WebM files up to 1 GB. Movies are stored as SQL chunks and streamed to signed-in members. Uploaders must own or have permission to share each movie. Members can report accounts; banned members can submit an appeal for admin review. The admin dashboard supports user search, recent-online counts, bans/unbans, report review, and appeal decisions. The Friend Map shares a user's location only after they opt in; location is visible to accepted friends and expires after 10 minutes.

## Privacy and storage

- The server listens on `127.0.0.1` only; it is not published to the internet.
- The `DIVerseAccounts` SQL Server LocalDB database belongs to the current Windows user's LocalDB instance and uses Windows integrated authentication.
- `database.sql` defines the account and single-owner admin tables. The app uses parameterized SQL commands; no database password is stored in the web files.
- Passwords are salted and hashed on the server. The admin list never exposes passwords or password hashes.
- Admin account listing requires the owner email, the admin password, and a server-side session. Regular users can retrieve only their own profile.
- Banned accounts cannot use normal app routes, but can submit an unban appeal through the restricted appeal page. The appeal and scam-report queues are visible only to the owner admin.
- Online counts reflect signed-in user sessions active within the last 10 minutes and reset when the local server restarts.
- Movie data is stored in 1 MB chunks in LocalDB. Uploads are capped at 1 GB and require an ownership/permission confirmation; only MP4 and WebM signatures are accepted.
- The owner email is an allowlist; this local app does not verify Gmail ownership or send email.
- Anyone with access to your Windows account can potentially access its LocalDB instance. Lock your computer and keep the admin password private.
- This is a local app, not a hosted website. Do not put real users' data into it if you need remote access, backups, or production-grade operations.

The app requires Windows PowerShell and SQL Server LocalDB.
