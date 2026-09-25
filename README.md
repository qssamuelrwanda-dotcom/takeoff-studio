# Takeoff Studio

Browser-based quantity take-off: trace PDFs or model a building, see it in 3D, and produce an NRM Bill of Quantities, bar schedule and bill of materials.

Single static file, no build step. Hosted on Vercel; every push to `main` publishes automatically.

| File | Purpose |
|---|---|
| `index.html` | The whole app |
| `version.json` | Current version. Open copies of the app check it and offer "Reload now" when it changes |
| `vercel.json` | Stops browsers caching old copies of the app |
| `supabase-setup.sql` | Database tables, privacy rules and live updates for accounts. Run once in Supabase → SQL Editor |

## Publishing an update
1. Replace `index.html` with the new build.
2. Replace `version.json` with the one shipped alongside it; its `version` must match `APP_VER` inside `index.html`.
3. Commit to `main`. Vercel redeploys in about a minute, and users see the update banner.

Users' projects are saved in their own browser (key `takeoffstudio.project.v1`) and survive updates.

## Accounts (Supabase)
Project `fafolvtalqfqerhcorhe`. The app holds only the public *publishable* key. Never put the secret or service_role key in this repository.
Authentication → URL Configuration: Site URL and Redirect URLs must list the live address of this app.
