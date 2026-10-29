/*
 * Standalone GNUstep Prompt. GPL-2.0-or-later; see COPYING.
 * Font-panel responder integration follows Ycode AppController:
 * Copyright (C) 2025 Free Software Foundation; author Gregory Casamento.
 */
#import "AppController.h"
#import "TerminalView.h"
#import "TerminalPreferences.h"

/* Font actions travel through the main window responder chain. */
@interface TerminalFontButton : NSButton
@end
@implementation TerminalFontButton
- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (void)changeFont:(id)sender
{
  [(AppController *)[self target] changeFont:sender];
}
@end

@interface TerminalPreferencesPanel : NSPanel
@end
@implementation TerminalPreferencesPanel
- (BOOL)canBecomeMainWindow
{
  return YES;
}
@end

static void
add_item (NSMenu *menu, NSString *title, SEL action, NSString *key, id target)
{
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:key];
  [item setTarget:target];
  [menu addItem:item];
  RELEASE (item);
}

static NSTextField *
label (NSView *view, NSString *text, CGFloat y)
{
  NSTextField *field = AUTORELEASE (
      [[NSTextField alloc] initWithFrame:NSMakeRect (20, y, 190, 24)]);
  [field setStringValue:text];
  [field setEditable:NO];
  [field setSelectable:NO];
  [field setBordered:NO];
  [field setDrawsBackground:NO];
  [view addSubview:field];
  return field;
}

@interface AppController (ProfileWindows)
- (TerminalView *)openDirectory:(NSString *)directory
                        profile:(NSString *)profile;
@end

@implementation AppController
- (id)init
{
  if ((self = [super init]))
    _windows = [NSMutableArray new];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  RELEASE (_windows);
  RELEASE (_preferences);
  RELEASE (_help);
  [super dealloc];
}

- (void)buildMenus
{
  NSMenu *main = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Prompt"]);
  add_item (main, @"About Prompt", @selector (orderFrontStandardAboutPanel:),
            @"", NSApp);
  add_item (main, @"Preferences…", @selector (showPreferences:), @",", self);
  NSMenu *session = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Session"]);
  add_item (main, @"Session", NULL, @"", nil);
  [main setSubmenu:session forItem:[main itemWithTitle:@"Session"]];
  add_item (session, @"New Terminal", @selector (newTerminal:), @"n", self);
  add_item (session, @"New Terminal in Directory…",
            @selector (newTerminalInDirectory:), @"o", self);
  add_item (session, @"Close Terminal", @selector (toggleTerminal:), @"t",
            self);
  add_item (session, @"Restart Shell", @selector (restart:), @"", nil);
  add_item (session, @"Close Session", @selector (performClose:), @"w", nil);
  NSMenu *edit = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Edit"]);
  add_item (main, @"Edit", NULL, @"", nil);
  [main setSubmenu:edit forItem:[main itemWithTitle:@"Edit"]];
  add_item (edit, @"Copy", @selector (copy:), @"c", nil);
  add_item (edit, @"Paste", @selector (paste:), @"v", nil);
  add_item (edit, @"Select All", @selector (selectAll:), @"a", nil);
  NSMenu *window = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Window"]);
  add_item (main, @"Window", NULL, @"", nil);
  [main setSubmenu:window forItem:[main itemWithTitle:@"Window"]];
  add_item (window, @"Minimize", @selector (performMiniaturize:), @"m", nil);
  [NSApp setWindowsMenu:window];
  add_item (main, @"Prompt Help", @selector (showHelp:), @"?", self);
  add_item (main, @"Hide Prompt", @selector (hide:), @"h", NSApp);
  add_item (main, @"Quit", @selector (terminate:), @"q", NSApp);
  [NSApp setMainMenu:main];
  /* GNUstep uses the process name for the menu window when installing it. */
  [[main window] setTitle:@"Prompt"];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  [self buildMenus];
  NSArray *args = [[NSProcessInfo processInfo] arguments];
  NSUInteger index = [args indexOfObject:@"--directory"];
  NSString *directory = index != NSNotFound && index + 1 < [args count]
                            ? [args objectAtIndex:index + 1]
                            : NSHomeDirectory ();
  [self openDirectory:directory];
}

- (TerminalView *)openDirectory:(NSString *)directory
{
  return [self openDirectory:directory
                     profile:[TerminalPreferences defaultProfileName]];
}

- (TerminalView *)openDirectory:(NSString *)directory
                        profile:(NSString *)profile
{
  TerminalPreferences *preferences
      = AUTORELEASE ([[TerminalPreferences alloc] initWithProfileName:profile]);
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect (100, 100, 100, 100)
                styleMask:NSTitledWindowMask | NSClosableWindowMask
                          | NSMiniaturizableWindowMask | NSResizableWindowMask
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [window setReleasedWhenClosed:NO];
  [window setMinSize:NSMakeSize (240, 140)];
  [window setTitle:[NSString stringWithFormat:@"Prompt — %@", directory]];
  TerminalView *terminal =
      [[TerminalView alloc] initWithFrame:[[window contentView] bounds]];
  [terminal setProfileName:profile];
  [window setContentView:terminal];
  [window setContentSize:[terminal
                             contentSizeForColumns:[preferences terminalColumns]
                                              rows:[preferences terminalRows]]];
  RELEASE (terminal);
  [window setDelegate:self];
  [_windows addObject:window];
  _lastTerminalWindow = window;
  RELEASE (window);
  [window makeKeyAndOrderFront:nil];
  [window makeFirstResponder:terminal];
  NSError *error = nil;
  if (![terminal startInDirectory:directory error:&error])
    {
      [[NSAlert alertWithError:error] runModal];
      [window close];
      return nil;
    }
  return terminal;
}

- (void)newTerminal:(id)sender
{
  [self openDirectory:NSHomeDirectory ()];
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
  if ([_windows containsObject:[notification object]])
    _lastTerminalWindow = [notification object];
}

- (void)toggleTerminal:(id)sender
{
  if (!_lastTerminalWindow)
    [self newTerminal:sender];
  else if ([_lastTerminalWindow isVisible])
    [_lastTerminalWindow orderOut:sender];
  else
    {
      [_lastTerminalWindow makeKeyAndOrderFront:sender];
      [_lastTerminalWindow
          makeFirstResponder:[_lastTerminalWindow contentView]];
    }
  if ([sender isKindOfClass:[NSMenuItem class]])
    [self validateMenuItem:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
  if ([item action] == @selector (toggleTerminal:))
    [item setTitle:[_lastTerminalWindow isVisible] ? @"Close Terminal"
                                                   : @"Open Terminal"];
  return YES;
}

- (void)newTerminalInDirectory:(id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setCanChooseFiles:NO];
  [panel setCanChooseDirectories:YES];
  [panel setAllowsMultipleSelection:NO];
  [panel setTitle:@"Choose Working Directory"];
  if ([panel runModal] == NSOKButton)
    [self openDirectory:[panel filename]];
}

- (BOOL)windowShouldClose:(id)window
{
  if (![_windows containsObject:window]
      || ![(TerminalView *)[window contentView] requiresCloseConfirmation])
    return YES;
  return NSRunAlertPanel (@"Close terminal session?",
                          @"Processes are still running in this terminal. "
                           @"Closing the session will terminate them.",
                          @"Cancel", @"Close Session", nil) == NSAlertAlternateReturn;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
  NSEnumerator *enumerator = [_windows objectEnumerator];
  NSWindow *window;
  while ((window = [enumerator nextObject]))
    if ([(TerminalView *)[window contentView] requiresCloseConfirmation])
      return NSRunAlertPanel (@"Quit Prompt?",
                              @"Processes are still running in a terminal. "
                               @"Quitting will terminate all sessions.",
                              @"Cancel", @"Quit", nil) == NSAlertAlternateReturn
                 ? NSTerminateNow : NSTerminateCancel;
  return NSTerminateNow;
}

- (void)windowWillClose:(NSNotification *)notification
{
  NSWindow *window = [notification object];
  if ([_windows containsObject:window])
    {
      [(TerminalView *)[window contentView] stop];
      AUTORELEASE (RETAIN (window));
      [_windows removeObject:window];
      if (_lastTerminalWindow == window)
        _lastTerminalWindow = [_windows lastObject];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
  NSEnumerator *enumerator = [_windows objectEnumerator];
  NSWindow *window;
  while ((window = [enumerator nextObject]))
    [(TerminalView *)[window contentView] stop];
  [TerminalView waitForChildCleanup];
}

- (void)refreshPreferences
{
  [_profiles removeAllItems];
  [_profiles addItemsWithTitles:[TerminalPreferences profileNames]];
  [_profiles selectItemWithTitle:[TerminalPreferences selectedProfileName]];
  [_profileName setStringValue:[TerminalPreferences selectedProfileName]];
  BOOL builtIn = [[TerminalPreferences selectedProfileName] isEqual:@"Default"];
  [_renameProfile setEnabled:!builtIn];
  [_deleteProfile setEnabled:!builtIn];
  [_defaultProfile
      setEnabled:![[TerminalPreferences selectedProfileName]
                     isEqual:[TerminalPreferences defaultProfileName]]];
  [_profileStatus
      setStringValue:[NSString stringWithFormat:@"New windows use: %@",
                                                [TerminalPreferences
                                                    defaultProfileName]]];
  [_fontButton
      setTitle:[NSString stringWithFormat:@"%@ %.0f pt…",
                                          [[TerminalPreferences terminalFont]
                                              displayName],
                                          [[TerminalPreferences terminalFont]
                                              pointSize]]];
  [_foreground setColor:[TerminalPreferences terminalForegroundColor]];
  [_background setColor:[TerminalPreferences terminalBackgroundColor]];
  [_cursor setColor:[TerminalPreferences terminalCursorColor]];
  [_shape selectItemAtIndex:[TerminalPreferences terminalCursorShape]];
  [_columns setIntegerValue:[TerminalPreferences terminalColumns]];
  [_rows setIntegerValue:[TerminalPreferences terminalRows]];
  [_history setIntegerValue:[TerminalPreferences terminalScrollbackLines]];
  [_bell setState:[TerminalPreferences terminalAudibleBell]];
  [_blink setState:[TerminalPreferences terminalCursorBlink]];
  [_closeOnExit setState:[TerminalPreferences terminalCloseOnExit]];
  [_confirmClose setState:[TerminalPreferences terminalConfirmClose]];
  [_showProcess setState:[TerminalPreferences terminalShowProcess]];
}

- (void)showPreferences:(id)sender
{
  if (!_preferences)
    {
      _preferences = [[TerminalPreferencesPanel alloc]
          initWithContentRect:NSMakeRect (180, 180, 720, 610)
                    styleMask:NSTitledWindowMask | NSClosableWindowMask
                      backing:NSBackingStoreBuffered
                        defer:NO];
      [_preferences setTitle:@"Prompt Preferences"];
      [_preferences setReleasedWhenClosed:NO];
      NSView *view = [_preferences contentView];
      label (view, @"Fixed-pitch font (6–72 pt)", 345);
      _fontButton = AUTORELEASE ([[TerminalFontButton alloc]
          initWithFrame:NSMakeRect (210, 340, 250, 32)]);
      [_fontButton setTarget:self];
      [_fontButton setAction:@selector (chooseFont:)];
      [view addSubview:_fontButton];
      NSString *names[] = { @"Foreground", @"Background", @"Cursor color" };
      NSColorWell **wells[] = { &_foreground, &_background, &_cursor };
      int i;
      for (i = 0; i < 3; i++)
        {
          CGFloat y = 295 - i * 45;
          label (view, names[i], y);
          *wells[i] = AUTORELEASE ([[NSColorWell alloc]
              initWithFrame:NSMakeRect (210, y - 3, 75, 30)]);
          [*wells[i] setTarget:self];
          [*wells[i] setAction:@selector (changeColors:)];
          [view addSubview:*wells[i]];
        }
      label (view, @"Cursor shape", 160);
      _shape = AUTORELEASE (
          [[NSPopUpButton alloc] initWithFrame:NSMakeRect (210, 157, 250, 28)]);
      [_shape
          addItemsWithTitles:[NSArray arrayWithObjects:@"Program controlled",
                                                       @"Filled block",
                                                       @"Outline block",
                                                       @"Vertical line",
                                                       @"Underline", nil]];
      [_shape setTarget:self];
      [_shape setAction:@selector (changeSettings:)];
      [view addSubview:_shape];
      label (view, @"History lines (0–50,000)", 118);
      _history = AUTORELEASE (
          [[NSTextField alloc] initWithFrame:NSMakeRect (210, 115, 120, 26)]);
      [_history setTarget:self];
      [_history setAction:@selector (changeSettings:)];
      [_history setDelegate:(id)self];
      [view addSubview:_history];
      _bell = AUTORELEASE (
          [[NSButton alloc] initWithFrame:NSMakeRect (20, 72, 190, 28)]);
      _blink = AUTORELEASE (
          [[NSButton alloc] initWithFrame:NSMakeRect (230, 72, 220, 28)]);
      [_bell setTitle:@"Audible bell"];
      [_blink setTitle:@"Blink active cursor"];
      NSArray *checks = [NSArray arrayWithObjects:_bell, _blink, nil];
      for (i = 0; i < 2; i++)
        {
          NSButton *button = [checks objectAtIndex:i];
          [button setButtonType:NSSwitchButton];
          [button setTarget:self];
          [button setAction:@selector (changeSettings:)];
          [view addSubview:button];
        }
      /* Make room below the existing controls for the new-window grid settings.
       */
      {
        NSEnumerator *enumerator = [[view subviews] objectEnumerator];
        NSView *control;
        while ((control = [enumerator nextObject]) != nil)
          {
            NSPoint origin = [control frame].origin;
            origin.y += 110;
            [control setFrameOrigin:origin];
          }
      }
      [label (view, @"New window size (characters)", 145)
          setFrameSize:NSMakeSize (300, 24)];
      label (view, @"Columns (2–1,000)", 112);
      label (view, @"Rows (2–1,000)", 77);
      _columns = AUTORELEASE (
          [[NSTextField alloc] initWithFrame:NSMakeRect (210, 110, 120, 26)]);
      _rows = AUTORELEASE (
          [[NSTextField alloc] initWithFrame:NSMakeRect (210, 75, 120, 26)]);
      {
        NSEnumerator *enumerator =
            [[NSArray arrayWithObjects:_columns, _rows, nil] objectEnumerator];
        NSTextField *field;
        while ((field = [enumerator nextObject]) != nil)
          {
            [field setTarget:self];
            [field setAction:@selector (changeDimensions:)];
            [field setDelegate:(id)self];
            [view addSubview:field];
          }
      }
      NSButton *reset = AUTORELEASE (
          [[NSButton alloc] initWithFrame:NSMakeRect (290, 20, 170, 32)]);
      [reset setTitle:@"Restore Defaults"];
      [reset setTarget:self];
      [reset setAction:@selector (restoreDefaults:)];
      [view addSubview:reset];
      {
        NSEnumerator *enumerator = [[view subviews] objectEnumerator];
        NSView *control;
        while ((control = [enumerator nextObject]) != nil)
          {
            NSPoint origin = [control frame].origin;
            origin.x += 240;
            [control setFrameOrigin:origin];
          }
      }
      _closeOnExit = AUTORELEASE (
          [[NSButton alloc] initWithFrame:NSMakeRect (260, 500, 440, 28)]);
      [_closeOnExit setTitle:@"Close terminal session when process exits"];
      [_closeOnExit setButtonType:NSSwitchButton];
      [_closeOnExit setTarget:self];
      [_closeOnExit setAction:@selector (changeSettings:)];
      [view addSubview:_closeOnExit];
      NSButton **sessionChecks[] = { &_confirmClose, &_showProcess };
      NSString *sessionTitles[] = { @"Confirm closing sessions with running jobs",
                                    @"Show running process in window title" };
      for (i = 0; i < 2; i++)
        {
          NSButton *button = AUTORELEASE ([[NSButton alloc]
              initWithFrame:NSMakeRect (260, 570 - i * 35, 440, 28)]);
          *sessionChecks[i] = button;
          [button setTitle:sessionTitles[i]];
          [button setButtonType:NSSwitchButton];
          [button setTarget:self];
          [button setAction:@selector (changeSettings:)];
          [view addSubview:button];
        }
      label (view, @"Profiles", 460);
      _profiles = AUTORELEASE (
          [[NSPopUpButton alloc] initWithFrame:NSMakeRect (20, 422, 210, 28)]);
      [_profiles setTarget:self];
      [_profiles setAction:@selector (selectProfile:)];
      [view addSubview:_profiles];
      _profileName = AUTORELEASE (
          [[NSTextField alloc] initWithFrame:NSMakeRect (20, 382, 210, 26)]);
      [_profileName
          setToolTip:@"Enter a unique name, then choose Save Copy or Rename."];
      [view addSubview:_profileName];
      NSArray *titles =
          [NSArray arrayWithObjects:@"Save Copy…", @"Rename", @"Delete…",
                                    @"Use as Default", @"Open New Terminal",
                                    @"Apply to Current Terminal", nil];
      SEL actions[] = {
        @selector (saveProfileCopy:),        @selector (renameProfile:),
        @selector (deleteProfile:),          @selector (makeDefaultProfile:),
        @selector (newTerminalWithProfile:), @selector (applyProfile:)
      };
      for (i = 0; i < 6; i++)
        {
          NSButton *button = AUTORELEASE ([[NSButton alloc]
              initWithFrame:NSMakeRect (20, 340 - i * 40, 210, 32)]);
          [button setTitle:[titles objectAtIndex:i]];
          [button setTarget:self];
          [button setAction:actions[i]];
          [view addSubview:button];
          if (i == 1)
            _renameProfile = button;
          if (i == 2)
            _deleteProfile = button;
          if (i == 3)
            _defaultProfile = button;
        }
      _profileStatus = label (view, @"", 80);
      [_profileStatus setFrameSize:NSMakeSize (210, 50)];
      NSTextField *hint = label (
          view, @"Enter a name above to Save Copy. Edits save automatically.",
          20);
      [hint setFrameSize:NSMakeSize (210, 55)];
    }
  [self refreshPreferences];
  [_preferences makeKeyAndOrderFront:nil];
}

- (void)selectProfile:(id)sender
{
  [_preferences makeFirstResponder:nil];
  [TerminalPreferences selectProfile:[_profiles titleOfSelectedItem]];
  [self refreshPreferences];
}

- (void)profileNameError
{
  NSRunAlertPanel (@"Profile Name",
                   @"Enter a unique name (1–80 characters) in the name field, "
                   @"without leading or trailing spaces.",
                   @"OK", nil, nil);
}

- (void)saveProfileCopy:(id)sender
{
  [_preferences makeFirstResponder:nil];
  if (![TerminalPreferences
          duplicateSelectedProfileWithName:[_profileName stringValue]])
    {
      [self profileNameError];
      return;
    }
  [self refreshPreferences];
}

- (void)renameProfile:(id)sender
{
  [_preferences makeFirstResponder:nil];
  if (![TerminalPreferences renameSelectedProfile:[_profileName stringValue]])
    {
      [self profileNameError];
      return;
    }
  [self refreshPreferences];
}

- (void)deleteProfile:(id)sender
{
  NSString *name = [TerminalPreferences selectedProfileName];
  if ([name isEqual:@"Default"])
    return;
  if (NSRunAlertPanel (
          @"Delete Profile",
          @"Delete “%@”? Terminals using it will switch to Default.", @"Cancel",
          @"Delete", nil, name)
      != NSAlertAlternateReturn)
    return;
  [TerminalPreferences deleteSelectedProfile];
  [self refreshPreferences];
}

- (void)makeDefaultProfile:(id)sender
{
  [TerminalPreferences
      setDefaultProfileName:[TerminalPreferences selectedProfileName]];
  [self refreshPreferences];
}

- (void)newTerminalWithProfile:(id)sender
{
  [_preferences makeFirstResponder:nil];
  [self openDirectory:NSHomeDirectory ()
              profile:[TerminalPreferences selectedProfileName]];
}

- (void)applyProfile:(id)sender
{
  [_preferences makeFirstResponder:nil];
  if (!_lastTerminalWindow)
    {
      NSBeep ();
      return;
    }
  [(TerminalView *)[_lastTerminalWindow contentView]
      setProfileName:[TerminalPreferences selectedProfileName]];
}

- (void)chooseFont:(id)sender
{
  NSFontManager *manager = [NSFontManager sharedFontManager];
  [_preferences makeKeyAndOrderFront:nil];
  [_preferences makeMainWindow];
  [_preferences makeFirstResponder:_fontButton];
  [manager setAction:@selector (changeFont:)];
  [manager setSelectedFont:[TerminalPreferences terminalFont] isMultiple:NO];
  [manager orderFrontFontPanel:sender];
}

- (void)changeFont:(id)sender
{
  NSFont *font = [sender convertFont:[TerminalPreferences terminalFont]];
  if (![TerminalPreferences isTerminalFont:font] || [font pointSize] < 6 ||
      [font pointSize] > 72)
    {
      NSBeep ();
      return;
    }
  [TerminalPreferences setTerminalFont:font];
  [[NSFontManager sharedFontManager] setSelectedFont:font isMultiple:NO];
  [self refreshPreferences];
}

- (void)changeColors:(id)sender
{
  [TerminalPreferences setTerminalForegroundColor:[_foreground color]
                                  backgroundColor:[_background color]];
  [TerminalPreferences setTerminalCursorColor:[_cursor color]];
}

- (void)changeSettings:(id)sender
{
  [TerminalPreferences setTerminalCursorShape:[_shape indexOfSelectedItem]];
  NSScanner *scanner = [NSScanner scannerWithString:[_history stringValue]];
  int lines;
  if ([scanner scanInt:&lines] && [scanner isAtEnd] && lines >= 0
      && lines <= 50000)
    [TerminalPreferences setTerminalScrollbackLines:lines];
  else
    {
      NSBeep ();
      [_history setIntegerValue:[TerminalPreferences terminalScrollbackLines]];
    }
  [TerminalPreferences setTerminalAudibleBell:[_bell state] == NSOnState];
  [TerminalPreferences setTerminalCursorBlink:[_blink state] == NSOnState];
  [TerminalPreferences
      setTerminalCloseOnExit:[_closeOnExit state] == NSOnState];
  [TerminalPreferences setTerminalConfirmClose:[_confirmClose state] == NSOnState];
  [TerminalPreferences setTerminalShowProcess:[_showProcess state] == NSOnState];
}

- (void)changeDimensions:(id)sender
{
  int columns, rows;
  NSScanner *columnScanner =
      [NSScanner scannerWithString:[_columns stringValue]];
  NSScanner *rowScanner = [NSScanner scannerWithString:[_rows stringValue]];
  if ([columnScanner scanInt:&columns] && [columnScanner isAtEnd] &&
      [rowScanner scanInt:&rows] && [rowScanner isAtEnd] && columns >= 2
      && columns <= 1000 && rows >= 2 && rows <= 1000)
    [TerminalPreferences setTerminalColumns:columns rows:rows];
  else
    NSBeep ();
  [_columns setIntegerValue:[TerminalPreferences terminalColumns]];
  [_rows setIntegerValue:[TerminalPreferences terminalRows]];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
  if ([notification object] == _columns || [notification object] == _rows)
    [self changeDimensions:[notification object]];
  if ([notification object] == _history)
    [self changeSettings:_history];
}

- (void)restoreDefaults:(id)sender
{
  [TerminalPreferences resetTerminalPreferences];
  [self refreshPreferences];
}

- (void)showHelp:(id)sender
{
  if (!_help)
    {
      _help = [[NSWindow alloc]
          initWithContentRect:NSMakeRect (160, 120, 730, 580)
                    styleMask:NSTitledWindowMask | NSClosableWindowMask
                              | NSResizableWindowMask
                      backing:NSBackingStoreBuffered
                        defer:NO];
      [_help setTitle:@"Prompt Help"];
      [_help setReleasedWhenClosed:NO];
      NSScrollView *scroll = AUTORELEASE (
          [[NSScrollView alloc] initWithFrame:[[_help contentView] bounds]]);
      [scroll setHasVerticalScroller:YES];
      [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
      NSTextView *text = AUTORELEASE (
          [[NSTextView alloc] initWithFrame:[[scroll contentView] bounds]]);
      [text setEditable:NO];
      [text setVerticallyResizable:YES];
      [text setHorizontallyResizable:NO];
      [text setAutoresizingMask:NSViewWidthSizable];
      [[text textContainer] setWidthTracksTextView:YES];
      [text setFont:[NSFont userFixedPitchFontOfSize:13]];
      NSString *path = [[NSBundle mainBundle] pathForResource:@"Help"
                                                       ofType:@"txt"];
      NSString *help = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
      [text setString:help ? help
                           : @"Prompt Help could not be loaded from the "
                             @"application bundle."];
      [scroll setDocumentView:text];
      [_help setContentView:scroll];
    }
  [_help makeKeyAndOrderFront:nil];
}
@end
