# Verification

Run `xvfb-run -a make check` from the repository root, or `make check` with a
working display. The GNUstep make target builds both the application and test
executable. Tests require `vim`, `less`, `top`, `python3`, and `seq` for the
interactive integration scenarios (Vim is conditional on `/usr/bin/vim`).
Tests use their own `TerminalTests` defaults domain and restore its prior
Terminal settings and profile keys. Temporary files and rendering PNGs are left in the printed
`/tmp/terminal-tests-PID` directory for inspection.

Verified on GNU/Linux with the configured GNUstep Make 2.9.3 / Base / GUI and
Xvfb with Window Maker on 2026-10-23: **149 checks, 0 failures**. The application build completed
without compiler warnings. GNUstep emitted runtime diagnostics about installed
Color-picker duplicates, button-cell method signatures, and test service names;
the X11 backend also emitted RenderBadPicture diagnostics during teardown.
These did not prevent native panel actions or pixel verification.

The suite covers:

- Application-owned engine integration: focus reporting, program-selected
  cursor shape/blink, double underline, mouse press/drag/release, and hard reset
  of reporting modes and the alternate screen.

- Fragmented ANSI and UTF-8, wide/combining characters, DEC graphics, cursor
  addressing, erase/insert/delete, scroll regions, alternate screens, truecolor
  and indexed colors, device queries, application cursor/keypad and F5 input.
- Primary-screen and history reflow on narrowing/widening, wide-glyph padding,
  cursor preservation, and resizing while the primary screen is hidden.
- Selection paste survives pager exit, keeps the clipboard separate, and uses
  bracketed paste for externally supplied selection text.
- Mouse SGR reporting and Shift bypass, bracketed paste, selection/copy,
  scrollbar actions, fractional trackpad deltas, Shift-Page Up, return to live
  output on typing/paste, reading-position preservation, the 5,000-line history
  cap and alternate-screen history isolation.
- Real PTY shells in directories with spaces, terminal identity, initial size
  including the scrollbar, resize/SIGWINCH, Ctrl-C, shell exit/restart, close,
  descriptor shutdown, and shell/foreground-job cleanup without zombies.
- Real Vim edit/save/exit, less alternate-screen entry/exit, interactive top and
  resizing during top. A hangup-ignoring Python job is killed and reaped.
- A 1 MiB input queue against a blocked reader while the GUI run loop and resize
  remain responsive.
- Actual Fonts-panel `modifyFontViaPanel:` responder dispatch and Color-panel
  activation/actions. Live font changes preserve shell PID and update PTY size.
- Pixel checks for all five cursor choices, contrasting text under a filled
  block, default foreground/background colors, and preserved explicit ANSI red.
- New windows use an 80 by 25 grid and place the history scroller on the left.
- Mapped windows report default and custom grid dimensions through `stty size`,
  including window-manager resize-increment constraints.
- Invalid saved values, history limits, Restore Defaults, new-window settings,
  and settings reloaded by a separate executable process.
- Dynamic Open Terminal / Close Terminal titles and same-session preservation.
- Named profile copies, isolated live updates, default and explicit new-window
  profiles, applying profiles without restarting shells, rename/delete behavior,
  invalid names, per-profile reset, and persistence across processes.

A separate smoke run launched `Prompt.app/Prompt --directory /tmp` on an
isolated display, typed a real shell command, opened Help and Preferences using
keyboard menu shortcuts, captured and visually inspected both windows, and
quit through the menu shortcut with exit status 0. Help loaded the bundled
offline text. These smoke screenshots were saved as `/tmp/terminal-gui-*.png`.

Not established by these checks: exhaustive xterm conformance, every font and
Unicode script, physical trackpad hardware, other GNUstep backends, or non-Linux
runtime behavior. See `Resources/Help.txt` for supported behavior and known
limitations. This is a text terminal, without graphics protocols, input-method
composition UI.

## Compiler regression (no display required)

Run `Tests/check-compile.sh` to use the configured GNUstep compiler, or select a compiler with `CC=gcc-16` /
`CC=clang`. This compiles the real TerminalView implementation and emits
Objective-C method metadata; `-fsyntax-only` does not exercise type encoding.
Warnings are errors except for unused-result warnings in PTY error handling.
Clang installations may need
`OBJCFLAGS=-I$(gcc -print-file-name=include)` to find GNU runtime headers.

The GUI suite also checks cursor and mouse mode forwarding and ignored OSC
titles through the application-owned parser. The engine replacement removes
the libvterm union that caused the original GCC bit-field encoding failure;
system libvterm build modes no longer apply.
