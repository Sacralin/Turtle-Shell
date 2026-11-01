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
- **FindPlayer**: pick an online player and watch where they are (needs a
  Player Detector).

Tab, or tapping the bar along the top, switches between the work and the
Apps screen. The work carries on while an app runs.

To add an app: put its `.lua` in the top folder (no subfolders: older
updaters can't make them), add it to `manifest.txt`, and add it to
`apps.json`. Apps only ever arrive in a release.
