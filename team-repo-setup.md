# Creating your team repo

One-time setup, done once per team before S2. This produces your team's
own GitHub repo (starting from the template in `team-repo-template/`),
with SSH access from the Pi working. Once you're through this, you won't
need this file again — day-to-day reference lives in your own repo's
`README.md` from here on, not here.

## 1. Create your team's repo

The steps below create a throwaway staging copy, not your real working
copy — its only job is to get the template's content pushed to a new
GitHub repo. Your actual, permanent working copy gets created separately
afterward (step 3), on the Pi.

One team member, using a scratch location like `/tmp` so it's obviously
disposable:

```
cp -r ~/etw3-setup/team-repo-template /tmp/etw3-team-NN
cd /tmp/etw3-team-NN
git init
git add -A && git commit -m "Start from etw3 team template"
```

Then create a new, **empty** repo on GitHub under **your own personal
GitHub account** — don't initialize it with a README — and push:

```
git remote add origin <your-new-empty-repo-url>
git branch -M main
git push -u origin main
```

On GitHub, go to that new repo's Settings > Collaborators and add your
teammate so they can push too — the repo lives on one person's account,
so without this step the other teammate can't push.

Once the push succeeds, delete this staging copy — `rm -rf
/tmp/etw3-team-NN` — you won't use it again.

## 2. Let the Pi push and pull from your repo

Since your repo lives on a personal GitHub account, GitHub won't accept a
plain password over `git` — you need an SSH key on the Pi, added to your
GitHub account, before cloning or pushing from there will work:

```
ssh-keygen -t ed25519 -C "etw3-team-NN"
cat ~/.ssh/id_ed25519.pub
```

Copy that output into GitHub → Settings → SSH and GPG keys → New SSH key.
Then use the **SSH** form of your repo's URL
(`git@github.com:you/etw3-team-NN.git`, not `https://github.com/...`) in
`team.env` — the HTTPS form will just prompt for a password that no
longer works.

## 3. Clone it onto the Pi — your real working copy

Put your repo's SSH URL in `team.env` on the Pi (`TEAM_REPO_URL=...`) —
see the S1 setup handout — then run `./setup.sh` again. It clones your
repo into `~/etw3_ws/src/etw3_teamNN` and builds it alongside everything
else.

**`~/etw3_ws/src/etw3_teamNN` is your one real working copy from here
on** — not the `/tmp` staging copy from step 1, and not a copy sitting
anywhere else in your home directory. Every lab sheet's `cd` commands
assume you're working inside this path.

From here on, use your own repo's `README.md` for ongoing reference
(workspace layout, team conventions, safety gate) — this file's job is
done.
