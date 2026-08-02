# ETW III — team repo template

This is your team's ROS 2 workspace. Everything you write for the course —
lane following, the e-stop node, the stop-sign detector, launch files —
lives in `src/` here, as normal ROS 2 packages.

## Getting your own copy

This template lives as a subfolder inside `etw3-setup` (the same repo you
already cloned onto your Pi in S1) rather than its own separate GitHub
repo, so there's nothing extra to clone first.

**Important: the steps below create a throwaway staging copy, not your
real working copy.** Its only job is to get the template's content pushed
to a new GitHub repo. Your actual, permanent working copy gets created
separately, afterward, in the right place on the Pi — see "How this
connects to your robot" below. Don't keep coding in this staging copy.

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
/tmp/etw3-team-NN` — you won't use it again. Your real working copy comes
from the Pi cloning your new repo, in the next section.

## Letting the Pi push and pull from your repo

Since your repo lives on a personal GitHub account, GitHub won't accept a
plain password over `git` — you need an SSH key on the Pi, added to your
GitHub account, before cloning or pushing from there will work:

```
ssh-keygen -t ed25519 -C "etw3-team-NN"
cat ~/.ssh/id_ed25519.pub
```

Copy that output into GitHub → Settings → SSH and GPG keys → New SSH key.
Then use the **SSH** form of your repo's URL (`git@github.com:you/etw3-team-NN.git`,
not `https://github.com/...`) everywhere below and in `team.env` — the
HTTPS form will just prompt for a password that no longer works.

## How this connects to your robot

`etw3-setup/setup.sh` (the Pi provisioning script) clones **your** repo's
URL into `~/etw3_ws/src/etw3_teamNN` on the robot's Pi and builds it
alongside everything else. Put your repo's SSH URL in `team.env` on the Pi
(`TEAM_REPO_URL=...`) — see the S1 setup handout. After that, every time
you `git push` from your laptop, `git pull && colcon build` on the Pi picks
it up.

**`~/etw3_ws/src/etw3_teamNN` is your one real working copy from here on**
— not the `/tmp` staging copy from the previous section, and not a copy
sitting anywhere else in your home directory. Every lab sheet's `cd`
commands assume you're working inside this path.

You don't need to vendor any hardware driver code yourselves — the motor
and ultrasonic sensor drivers (`freenove_driver`) are already built into
the workspace by `setup.sh`. From any of your own nodes:

```python
from freenove_driver.motor import Ordinary_Car
from freenove_driver.ultrasonic import Ultrasonic
```

## Layout

```
etw3-team-NN/
  src/            # your ROS 2 packages go here, one directory each
  .gitignore      # excludes build/install/log, __pycache__, bags, model weights
```

There's nothing in `src/` yet on purpose — you'll create your first
package here in S2 (the lab sheet walks you through `ros2 pkg create`).

## Working as a team of two on one workspace

- Branch per feature, PR into `main`, at least one teammate reviews before
  merging — same as any real project.
- Don't commit `build/`, `install/`, or `log/` (already gitignored) —
  they're machine-specific and regenerate from `colcon build`.
- Don't commit rosbags or trained model weights to this repo (see
  `.gitignore`) — the Pi's SD card and your Git history will both thank
  you. Share large files via a drive/cloud folder instead.
- Keep commits scoped to one session's work where you can — it makes the
  "one problem you solved, one thing you'd do differently" part of the
  final presentation much easier to put together in Week 3.

## Safety gate

No autonomous driving before Milestone 1 (S3) is signed off — same rule as
everywhere else in this course. Teleop and bench-testing code before then
is fine and expected.
