# GNUstep Prompt

Independent, manual-reference-counted AppKit VT100/VT220 terminal emulator using the application-owned Objective-C engine from GNUstep Terminal and asynchronous, nonblocking POSIX PTY I/O. No Ycode libraries required.
New windows default to 80 columns by 25 rows, with the history scroller on the left.
Preferences supports named profiles for fonts, colors, cursor behavior, history,
bell, initial window dimensions, and automatic window closing on shell exit. Save copies, rename or delete profiles,
choose the default for new windows, and apply profiles to individual sessions.
Existing settings are preserved in the built-in Default profile.
Closing a session or quitting warns about active jobs. Profiles can disable
this confirmation or the running-process name shown beside the directory in
window titles. Both options default to enabled.
During resizing, a centered tooltip shows the current columns and rows until
the drag ends. On GNUstep/X11, this uses X11 mouse state (enabled when the
X11development package is available at build time).

Build with the configured GNUstep development environment:

```sh
make
./Prompt.app/Prompt
./Prompt.app/Prompt --directory /tmp
make check
```

Dependencies: GNUstep Make, Base and GUI, an Objective-C compiler, a GUI backend,
and POSIX UNIX 98 PTYs. The engine is included; no network downloads are needed.
`make install` uses the standard GNUstep application target (optional).
Prompt retains the existing preferences domain so saved settings carry over.
Preferences use the separate `io.github.gcasa.apps-terminal` domain. GAP
Terminal's `org.gap.Terminal` domain and legacy `Terminal` settings are left
untouched; existing settings from those domains are not imported.
Tests require a display; use `xvfb-run -a make check` for an isolated display.

See [bundled offline Help](Resources/Help.txt) for usage, lifecycle, preferences,
and compatibility limits. Help is also available from the application menu.

TerminalView and preference storage were adapted from Ycode under GPL-2.0-or-later.
Original copyright/author notices are retained. The standalone app has its own
classes, defaults domain and controller. The emulation engine is adapted from GNUstep Terminal under GPL-3.0-or-later,
with inspiration from libvterm. See [COPYING](COPYING) and [COPYING.engine](COPYING.engine). Engine provenance:
[Terminal/README.txt](Terminal/README.txt).

## Screenshot

<img width="739" height="957" alt="prompt_test" src="https://github.com/user-attachments/assets/a829e762-1b43-4bf3-86b3-bd5f5d91b5c2" />

The Prompt application supports ANSI and VT100/VT220 terminal emulation through its application-owned engine.
