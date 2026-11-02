# Turtle-Shell

The code the turtles and computers run (ComputerCraft: Tweaked).

To install on a computer, run:

    wget https://raw.githubusercontent.com/Sacralin/Turtle-Shell/release/startup.lua startup.lua
    reboot

## BitDriven OS and its apps

Every device runs BitDriven OS (`bitdriven.lua`, started by `startup.lua`,
the updater). `apps.json` lists the apps: which devices each runs on
(`turtle`, `computer`, `pocket`), what it needs next to it, and its files.
A device only installs the apps that run on it.

- **Colony** (`main.lua`): the colony's work. Starts by itself on turtles
  and computers, and is started again if it stops.
- **Info**: what's what on the device: release, job, position, fuel,
  disk, what's attached, the tracker, the last crash.
- **Pause work** (turtles): stops before the next move and waits there,
  through restarts, until it's run again.
- **Set position** (turtles): asks you where it is.
- **Settings**: the tracker's address and key, the world, the name, the
  job. A turtle's job can be "None (just the apps)": no work, no reports.
- **FindPlayer**: pick an online player and watch where they are (needs a
  Player Detector).

Tab, or tapping the bar along the top, switches between the work and the
Apps screen (in the Shell, Tab finishes names: tap the bar). The work
carries on while an app runs. The bar says when the work needs you, is
paused, or is about to restart for an update.

To add an app: put its `.lua` in the top folder (no subfolders: older
updaters can't make them), add it to `manifest.txt`, and add it to
`apps.json`. Apps only ever arrive in a release.
