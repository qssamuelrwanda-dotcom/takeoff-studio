# Takeoff Studio — website

| Path | What it is |
|---|---|
| `index.html` + `assets/` | Landing page (your home page) |
| `app/index.html` | The Takeoff Studio app, served at `/app/` |
| `app/version.json` | Current app version. Open copies show "A new version is available" when it changes |
| `admin/index.html` | Your private admin dashboard at `/admin/` (users, activity, suspend/restore) |
| `supabase-setup.sql` | Database tables, privacy rules, usage tracking and admin reports. Run in Supabase → SQL Editor |
| `vercel.json` | Caching rules so users always get the latest app |

## First-time setup (once)
1. **Supabase → SQL Editor → New query**: paste all of `supabase-setup.sql` → **Run**.
   The admin email is set near the end of the file (section 5). Change it if you'll sign in with another address.
2. **GitHub**: create repository `takeoff-studio`, then upload the *contents* of this folder (keep the `app`, `admin` and `assets` folders).
3. **Vercel**: Add New → Project → import `takeoff-studio` → Deploy (no settings to change).
4. **Supabase → Authentication → URL Configuration**:
   Site URL = `https://YOUR-SITE.vercel.app/app/`
   Redirect URLs → add `https://YOUR-SITE.vercel.app/**`
5. Open `https://YOUR-SITE.vercel.app/app/`, create your account with the admin email and confirm it from your inbox.
   Then open `/admin/` and sign in.

## Publishing an update (every time)
1. In GitHub open the repository → go into the `app` folder → **Add file → Upload files**.
2. Drag in the new `index.html` and `version.json` → **Commit changes**.
3. Vercel publishes within about a minute. Users see "A new version is available — Reload now".
If an update also includes a new `supabase-setup.sql`, run it again in Supabase (it is safe to re-run).

## Adding another administrator
Supabase → SQL Editor: `insert into public.app_admins(email) values ('name@example.com');`

## Before you invite users
- Replace `your-email@example.com` in `index.html` (privacy section) with your contact address.
- Connect your own email sender in Supabase → Authentication → Emails → SMTP (e.g. Resend or Brevo);
  the built-in sender only allows a few emails per hour.
