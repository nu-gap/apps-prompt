/*
 * This file is distributed under the GNU General Public License, version 3
 * or later. It comes WITHOUT ANY WARRANTY, including MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See <https://www.gnu.org/licenses/>.
 */

/*
   Copyright (C) 2026 Free Software Foundation

   Adapted from Ycode for standalone Terminal. Distributed under the GNU General
   Public License, version 2 or (at your option) any later version.
   See COPYING for details. There is no warranty.
*/

#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#import "TerminalView.h"
#import "TerminalPreferences.h"
#ifdef TERMINAL_X11_RESIZE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#import <GNUstepGUI/GSDisplayServer.h>
#endif
#include <math.h>
#include <errno.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <pwd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <dirent.h>
#endif
#endif

@interface TerminalView (Private)

- (void)copyToPasteboard:(NSPasteboard *)pasteboard;
- (void)pasteFromPasteboard:(NSPasteboard *)pasteboard;
- (NSPasteboard *)selectionPasteboard;
- (void)poll:(NSTimer *)timer;
- (void)updateSessionTitle;

- (void)queueBytes:(const char *)bytes length:(size_t)length;

- (BOOL)cellAtRow:(NSInteger)row column:(int)column cell:(TerminalGlyph *)cell;

- (int)pushLine:(int)columns cells:(const TerminalGlyph *)cells;

- (int)popLine:(int)columns cells:(TerminalGlyph *)cells;

- (void)clearHistory;

- (void)resizeTerminal;
- (void)updateResizeIndicator;
- (void)updateWindowSizeHints;

- (void)updateScroller;

- (void)scrollHistory:(NSScroller *)sender;

- (void)preferencesChanged:(NSNotification *)notification;

- (void)ringBell;
- (void)invalidateTerminalRect:(TerminalRect)rect;
- (void)invalidateCursorAt:(TerminalPosition)position;
- (BOOL)cursorCanBlink;
- (void)advanceBlink;

@end

static NSString *
terminal_cell_string (const TerminalGlyph *cell)
{
  unichar text[6 * 2];
  NSUInteger count = 0;
  int i;
  for (i = 0; i < 6 && cell->chars[i]; i++)
    {
      uint32_t c = cell->chars[i];
      if (c == (uint32_t)-1)
        break;
      if (c > 0xffff && c <= 0x10ffff)
        {
          c -= 0x10000;
          text[count++] = 0xd800 + (c >> 10);
          text[count++] = 0xdc00 + (c & 1023);
        }
      else if (c <= 0xffff)
        text[count++] = c;
    }
  return count ? [NSString stringWithCharacters:text length:count] : @" ";
}

static NSCondition *cleanup_condition;
static NSUInteger cleanup_count;

@implementation TerminalView
+ (void)initialize
{
  if (self == [TerminalView class])
    {
      cleanup_condition = [[NSCondition alloc] init];
#ifdef __linux__
      /* Reap orphaned jobs ourselves instead of relying on desktop PID 1. */
      prctl (PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#endif
    }
}

+ (void)waitForChildCleanup
{
  [cleanup_condition lock];
  while (cleanup_count)
    [cleanup_condition wait];
  [cleanup_condition unlock];
}

- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame]))
    {
      ASSIGNCOPY (_profileName, [TerminalPreferences defaultProfileName]);
      _master = _child = _session = -1;
      _selectionStart = _selectionEnd = -1;
      _cursorVisible = YES;
      _blinkOn = YES;
      _cursorShape = TerminalCursorBlock;
      _font = RETAIN ([TerminalPreferences terminalFont]);
      _boldFont = RETAIN ([[NSFontManager sharedFontManager]
          convertFont:_font
          toHaveTrait:NSBoldFontMask]);
      _cellWidth = ceil (
          [@"M"
              sizeWithAttributes:[NSDictionary
                                     dictionaryWithObject:_font
                                                   forKey:NSFontAttributeName]]
              .width);
      _cellHeight = ceil ([_font ascender] - [_font descender]);
      _history = [[NSMutableArray alloc] init];
      _pendingInput = [[NSMutableData alloc] init];
      CGFloat scrollerWidth = [NSScroller scrollerWidth];
      _historyScroller = [[NSScroller alloc]
          initWithFrame:NSMakeRect (0, 0, scrollerWidth, frame.size.height)];
      [_historyScroller
          setAutoresizingMask:NSViewMaxXMargin | NSViewHeightSizable];
      [_historyScroller setTarget:self];
      [_historyScroller setAction:@selector (scrollHistory:)];
      [self addSubview:_historyScroller];
      RELEASE (_historyScroller);
      _rows = MAX (2, (int)(frame.size.height / _cellHeight));
      _columns = MAX (
          2, (int)(MAX (0, frame.size.width - scrollerWidth) / _cellWidth));
      _terminal = [[TerminalParser_VT100 alloc] initWithTerminalScreen:self
                                   width:_columns height:_rows];
      [self preferencesChanged:nil];
      [[NSNotificationCenter defaultCenter]
          addObserver:self
             selector:@selector (preferencesChanged:)
                 name:TerminalPreferencesDidChangeNotification
               object:nil];
      [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self stop];
  if (_terminal)
    RELEASE (_terminal);
  RELEASE (_font);
  RELEASE (_boldFont);
  RELEASE (_history);
  RELEASE (_foregroundColor);
  RELEASE (_backgroundColor);
  RELEASE (_cursorColor);
  RELEASE (_pendingInput);
  RELEASE (_directory);
  RELEASE (_shellPath);
  RELEASE (_profileName);
#ifdef TERMINAL_X11_RESIZE
  if (_resizeDisplay)
    XCloseDisplay ((Display *)_resizeDisplay);
#endif
  DEALLOC;
}

- (NSSize)contentSizeForColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
  return NSMakeSize (columns * _cellWidth + [NSScroller scrollerWidth],
                     rows * _cellHeight);
}

- (BOOL)isFlipped
{
  return YES;
}

- (void)ringBell
{
  if (_audibleBell)
    NSBeep ();
}

- (NSString *)profileName
{
  return _profileName;
}

- (void)setProfileName:(NSString *)name
{
  if (![[TerminalPreferences profileNames] containsObject:name])
    return;
  ASSIGN (_profileName, name);
  [self preferencesChanged:nil];
}

- (void)preferencesChanged:(NSNotification *)notification
{
  if (notification && [notification object]
      && ![[notification object] isEqual:_profileName])
    return;
  NSString *replacement =
      [[notification userInfo] objectForKey:@"replacementProfile"];
  if (replacement)
    ASSIGN (_profileName, replacement);
  TerminalPreferences *preferences = AUTORELEASE (
      [[TerminalPreferences alloc] initWithProfileName:_profileName]);
  ASSIGN (_font, [preferences terminalFont]);
  NSFont *bold = [[NSFontManager sharedFontManager] convertFont:_font
                                                    toHaveTrait:NSBoldFontMask];
  ASSIGN (_boldFont, bold ? bold : _font);
  _cellWidth = ceil (
      [@"M" sizeWithAttributes:[NSDictionary
                                   dictionaryWithObject:_font
                                                 forKey:NSFontAttributeName]]
          .width);
  _cellHeight = ceil ([_font ascender] - [_font descender]);
  ASSIGN (_foregroundColor, [preferences terminalForegroundColor]);
  ASSIGN (_backgroundColor, [preferences terminalBackgroundColor]);
  ASSIGN (_cursorColor, [preferences terminalCursorColor]);
  _preferredCursorShape = [preferences terminalCursorShape];
  _scrollbackLimit = [preferences terminalScrollbackLines];
  if ([_history count] > _scrollbackLimit)
    {
      [_history removeObjectsInRange:NSMakeRange (0, [_history count]
                                                         - _scrollbackLimit)];
      _selectionStart = _selectionEnd = -1;
    }
  _scrollOffset = MIN (_scrollOffset, (NSInteger)[_history count]);
  _audibleBell = [preferences terminalAudibleBell];
  _allowCursorBlink = [preferences terminalCursorBlink];
  _closeOnExit = [preferences terminalCloseOnExit];
  _confirmClose = [preferences terminalConfirmClose];
  _showProcess = [preferences terminalShowProcess];
  [self updateSessionTitle];
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self resizeTerminal];
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (BOOL)isOpaque
{
  return YES;
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (BOOL)becomeFirstResponder
{
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [[self window] setAcceptsMouseMovedEvents:YES];
  [_terminal focusChanged:YES];
  [self setNeedsDisplay:YES];
  return YES;
}

- (BOOL)resignFirstResponder
{
  [_terminal focusChanged:NO];
  [self setNeedsDisplay:YES];
  return YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  {
    NSEnumerator *enumerator =
        [[NSArray arrayWithObjects:NSWindowWillCloseNotification,
                                   NSWindowDidBecomeKeyNotification,
                                   NSWindowDidResignKeyNotification, nil]
            objectEnumerator];
    NSString *name;
    while ((name = [enumerator nextObject]) != nil)
      {
        if ([self window])
          [center removeObserver:self name:name object:[self window]];
        if (window)
          [center addObserver:self
                     selector:[name isEqual:NSWindowWillCloseNotification]
                                  ? @selector (windowClosing:)
                                  : @selector (windowFocusChanged:)
                         name:name
                       object:window];
      }
  }
  [super viewWillMoveToWindow:window];
}

- (void)windowFocusChanged:(NSNotification *)notification
{
  /* Show the cursor immediately on either side of a focus change. */
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self setNeedsDisplay:YES];
}

- (void)windowClosing:(NSNotification *)notification
{
  [self stop];
}

- (BOOL)isRunning
{
  return _master >= 0;
}

- (void)invalidateTerminalRect:(TerminalRect)rect
{
  /* While browsing history, screen rows and visible rows no longer coincide. */
  if (_scrollOffset)
    {
      [self setNeedsDisplay:YES];
      return;
    }
  /* Include neighbouring cells so either half of a wide glyph is repainted. */
  int start = MAX (0, rect.start_col - 1),
      end = MIN (_columns, rect.end_col + 1);
  [self
      setNeedsDisplayInRect:NSMakeRect (
                                [NSScroller scrollerWidth] + start * _cellWidth,
                                rect.start_row * _cellHeight,
                                (end - start) * _cellWidth,
                                (rect.end_row - rect.start_row) * _cellHeight)];
}

- (void)invalidateCursorAt:(TerminalPosition)position
{
  if (_scrollOffset)
    return;
  TerminalRect rect
      = { position.row, position.row + 1, position.col, position.col + 1 };
  [self invalidateTerminalRect:rect];
}

- (BOOL)cursorCanBlink
{
  return _allowCursorBlink && _cursorBlink && [self isRunning] &&
         [NSApp isActive] && [[self window] isKeyWindow] &&
         [[self window] firstResponder] == self;
}

- (void)advanceBlink
{
  _blinkOn = !_blinkOn;
  if (![[self window] isVisible])
    return;
  if (_cursorVisible && !_scrollOffset && [self cursorCanBlink])
    {
      TerminalPosition cursor;
      cursor = [_terminal cursorPosition];
      [self invalidateCursorAt:cursor];
    }
  /* ANSI blinking text remains independent of the cursor preference/focus. */
  NSInteger first = (_alternateScreen ? 0 : [_history count]) - _scrollOffset;
  int row, col;
  for (row = 0; row < _rows; row++)
    for (col = 0; col < _columns; col++)
      {
        TerminalGlyph cell;
        if ([self cellAtRow:first + row column:col cell:&cell]
            && (cell.attributes & TerminalBlink))
          [self setNeedsDisplayInRect:NSMakeRect ([NSScroller scrollerWidth]
                                                      + col * _cellWidth,
                                                  row * _cellHeight,
                                                  MAX (1, cell.width)
                                                      * _cellWidth,
                                                  _cellHeight)];
      }
}

- (void)ts_sendCString:(const char *)bytes length:(int)length
{
  [self queueBytes:bytes length:length];
}

- (void)ts_goto:(int)x :(int)y
{
  TerminalPosition position = { y, x };
  if (position.row != _cursorPosition.row || position.col != _cursorPosition.col)
    {
      [self invalidateCursorAt:_cursorPosition];
      [self invalidateCursorAt:position];
      _cursorPosition = position;
    }
}

- (void)ts_putChar:(screen_char_t)cell count:(int)count at:(int)x :(int)y
{
  TerminalRect rect = { y, y + 1, x, x + count };
  [self invalidateTerminalRect:rect];
}

- (void)ts_setTitle:(NSString *)title type:(int)type
{
  /* Session titles are owned by the application. */
}

- (void)ts_setCursorVisible:(BOOL)visible
{
  if (_cursorVisible != visible)
    [self invalidateCursorAt:_cursorPosition];
  _cursorVisible = visible;
}

- (void)ts_setCursorShape:(int)shape blink:(BOOL)blink
{
  _cursorShape = shape;
  _cursorBlink = blink;
  [self invalidateCursorAt:_cursorPosition];
}

- (void)ts_setAlternate:(BOOL)enabled
{
  _alternateScreen = enabled;
  _scrollOffset = 0;
  _selectionStart = _selectionEnd = -1;
  [self setNeedsDisplay:YES];
}

- (void)ts_setMouse:(BOOL)enabled
{
  _mouseReporting = enabled;
}

- (void)ts_clearScrollback
{
  [self clearHistory];
}

- (void)ts_appendScrollback:(const screen_char_t *)cells count:(int)count
{
  TerminalGlyph *line = calloc (count, sizeof (*line));
  if (!line) return;
  int i;
  for (i = 0; i < count; i++) line[i] = cells[i].originalCell;
  [self pushLine:count cells:line];
  free (line);
}

- (BOOL)ts_popScrollback:(screen_char_t *)cells count:(int)count
{
  TerminalGlyph *line = calloc (count, sizeof (*line));
  if (!line) return NO;
  BOOL result = [self popLine:count cells:line];
  int i;
  for (i = 0; i < count; i++)
    {
      memset (&cells[i], 0, sizeof (cells[i]));
      cells[i].originalCell = line[i];
      if (!line[i].width) cells[i].ch = MULTI_CELL_GLYPH;
    }
  free (line);
  return result;
}

- (void)clearHistory
{
  [_history removeAllObjects];
  _scrollOffset = 0;
  _selectionStart = _selectionEnd = -1;
  [self setNeedsDisplay:YES];
}

- (int)pushLine:(int)columns cells:(const TerminalGlyph *)cells
{
  if (!_scrollbackLimit)
    return 1;
  [_history addObject:[NSData dataWithBytes:cells
                                     length:columns * sizeof (*cells)]];
  if ([_history count] > _scrollbackLimit)
    {
      [_history removeObjectAtIndex:0];
      _selectionStart = _selectionEnd = -1;
    }
  if (_scrollOffset)
    _scrollOffset = MIN ((NSInteger)[_history count], _scrollOffset + 1);
  return 1;
}

- (int)popLine:(int)columns cells:(TerminalGlyph *)cells
{
  NSData *line = [_history lastObject];
  if (!line)
    return 0;
  memset (cells, 0, columns * sizeof (*cells));
  int col;
  for (col = 0; col < columns; col++)
    {
      cells[col].width = 1;
      cells[col].fg.kind = TerminalColorDefaultForeground;
      cells[col].bg.kind = TerminalColorDefaultBackground;
    }
  memcpy (cells, [line bytes], MIN ([line length], columns * sizeof (*cells)));
  [_history removeLastObject];
  _scrollOffset = MIN (_scrollOffset, (NSInteger)[_history count]);
  return 1;
}

- (void)consumeData:(NSData *)data
{
  [_terminal processBytes:[data bytes] length:[data length]];
  [_terminal flush];
  [self updateScroller];
}

- (void)queueBytes:(const char *)bytes length:(size_t)length
{
  if (_master >= 0)
    [_pendingInput appendBytes:bytes length:length];
}

- (void)sendData:(NSData *)data
{
  [self queueBytes:[data bytes] length:[data length]];
}

- (void)setFrame:(NSRect)frame
{
  BOOL resized = !NSEqualSizes ([self frame].size, frame.size);
  [super setFrame:frame];
  if (_terminal && resized)
    [self updateResizeIndicator];
  /* NSTabView uses setFrame: when installing a selected tab. GNUstep does
   not route that change through setFrameSize:. */
  if (_terminal)
    [self resizeTerminal];
}

- (void)setFrameSize:(NSSize)size
{
  BOOL resized = !NSEqualSizes ([self frame].size, size);
  [super setFrameSize:size];
  if (_terminal && resized)
    [self updateResizeIndicator];
  if (_terminal)
    [self resizeTerminal];
}

- (BOOL)resizeMouseIsDown
{
#ifdef TERMINAL_X11_RESIZE
  if (!_resizeDisplay)
    _resizeDisplay = XOpenDisplay (NULL);
  if (_resizeDisplay)
    {
      Display *display = (Display *)_resizeDisplay;
      Window root, child;
      int rootX, rootY, x, y;
      unsigned int mask;
      if (XQueryPointer (display, DefaultRootWindow (display), &root, &child,
                         &rootX, &rootY, &x, &y, &mask))
        return (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;
    }
#endif
  return [NSEvent pressedMouseButtons] != 0;
}

- (void)checkResizeEnded:(NSTimer *)timer
{
  if ([self resizeMouseIsDown])
    return;
  _showResizeIndicator = NO;
  [_resizeTimer invalidate];
  DESTROY (_resizeTimer);
  [self setNeedsDisplay:YES];
}

- (void)viewWillStartLiveResize
{
  [super viewWillStartLiveResize];
  [self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize
{
  [super viewDidEndLiveResize];
  _showResizeIndicator = NO;
  [_resizeTimer invalidate];
  DESTROY (_resizeTimer);
  [self setNeedsDisplay:YES];
}

- (void)updateResizeIndicator
{
  /* GNUstep's X11 backend does not send live-resize callbacks. Query the
   pointer independently of events, since the window manager owns the drag. */
  if ([[self window] isVisible] && ![self inLiveResize] &&
      [self resizeMouseIsDown])
    {
      _showResizeIndicator = YES;
      if (!_resizeTimer)
        {
          _resizeTimer = RETAIN ([NSTimer
              timerWithTimeInterval:0.03
                             target:self
                           selector:@selector (checkResizeEnded:)
                           userInfo:nil
                            repeats:YES]);
          {
            NSEnumerator *enumerator =
                [[NSArray arrayWithObjects:NSDefaultRunLoopMode,
                                           NSEventTrackingRunLoopMode,
                                           NSModalPanelRunLoopMode, nil]
                    objectEnumerator];
            NSString *mode;
            while ((mode = [enumerator nextObject]) != nil)
              [[NSRunLoop mainRunLoop] addTimer:_resizeTimer forMode:mode];
          }
        }
    }
  [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self updateWindowSizeHints];
}

- (void)updateWindowSizeHints
{
  NSWindow *window = [self window];
  if (!window || [window contentView] != self)
    return;
  /* The X11 backend rewrites WM_NORMAL_HINTS during mapping and resizing,
     losing our PBaseSize. Without it, window managers use PMinSize as the
     grid origin, so the minimum content size must also be cell-aligned. */
  NSSize minimum = [window contentRectForFrameRect:
      NSMakeRect (0, 0, 240, 140)].size;
  minimum = [self contentSizeForColumns:
      MAX (2, (NSUInteger)ceil (MAX (0, minimum.width -
          [NSScroller scrollerWidth]) / _cellWidth))
      rows:MAX (2, (NSUInteger)ceil (MAX (0, minimum.height) / _cellHeight))];
  if (!NSEqualSizes ([window contentMinSize], minimum))
    [window setContentMinSize:minimum];
  NSSize increments = NSMakeSize (_cellWidth, _cellHeight);
  if (!NSEqualSizes ([window resizeIncrements], increments))
    [window setResizeIncrements:increments];
#ifdef TERMINAL_X11_RESIZE
  GSDisplayServer *server = GSServerForWindow (window);
  /* windowRef is an XID only for the X11 backend. */
  if (![server respondsToSelector:@selector (xDisplayRootWindow)])
    return;
  Display *display = (Display *)[server serverDevice];
  Window xid = (Window)[window windowRef];
  XSizeHints hints;
  XWindowAttributes attributes;
  long supplied;
  if (!xid || !XGetWMNormalHints (display, xid, &hints, &supplied)
      || !XGetWindowAttributes (display, xid, &attributes))
    return;
  /* Exclude the scroller and any client-side decoration from the grid count. */
  int baseWidth = MAX (0, attributes.width - [self bounds].size.width) +
                  [NSScroller scrollerWidth];
  int baseHeight = MAX (0, attributes.height - [self bounds].size.height);
  if (!(hints.flags & PBaseSize) || hints.base_width != baseWidth
      || hints.base_height != baseHeight)
    {
      hints.flags |= PBaseSize;
      hints.base_width = baseWidth;
      hints.base_height = baseHeight;
      XSetWMNormalHints (display, xid, &hints);
      XFlush (display);
    }
#endif
}

- (void)resizeTerminal
{
  [self updateWindowSizeHints];
  int rows
      = MIN (1000, MAX (2, (int)([self bounds].size.height / _cellHeight)));
  int cols = MIN (1000, MAX (2, (int)(MAX (0, [self bounds].size.width -
                                                  [NSScroller scrollerWidth])
                                      / _cellWidth)));
  [self updateScroller];
  if (rows == _rows && cols == _columns)
    return;
  _rows = rows;
  _columns = cols;
  _selectionStart = _selectionEnd = -1;
  [_terminal setTerminalScreenWidth:cols height:rows];
#ifndef _WIN32
  if (_master >= 0)
    {
      struct winsize size;
      memset (&size, 0, sizeof (size));
      size.ws_row = rows;
      size.ws_col = cols;
      ioctl (_master, TIOCSWINSZ, &size);
    }
#endif
  [_terminal flush];
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (BOOL)startInDirectory:(NSString *)directory error:(NSError **)error
{
  /* Use the final visible bounds before creating the PTY, and refresh an
   existing session when a previously hidden tab is selected again. */
  [self resizeTerminal];
  if ([self isRunning])
    return YES;
  int failure = 0;
#ifndef _WIN32
  NSDictionary *environment = [[NSProcessInfo processInfo] environment];
  NSString *shell = [environment objectForKey:@"SHELL"];
  if (![shell isAbsolutePath]
      || ![[NSFileManager defaultManager] isExecutableFileAtPath:shell])
    {
      struct passwd *user = getpwuid (getuid ());
      shell = user && user->pw_shell
                  ? [NSString stringWithUTF8String:user->pw_shell]
                  : @"/bin/sh";
    }
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:shell])
    shell = @"/bin/sh";
  ASSIGNCOPY (_shellPath, shell);
  BOOL isDirectory = NO;
  if (![directory isAbsolutePath]
      || ![[NSFileManager defaultManager] fileExistsAtPath:directory
                                               isDirectory:&isDirectory]
      || !isDirectory)
    failure = ENOENT;
  else
    {
      _master = posix_openpt (O_RDWR | O_NOCTTY);
      if (_master < 0)
        failure = errno;
      else if (grantpt (_master) < 0 || unlockpt (_master) < 0)
        failure = errno;
    }
  char *slaveName = !failure ? ptsname (_master) : NULL;
  if (!failure && !slaveName)
    failure = errno ? errno : EIO;
  if (!failure)
    {
      fcntl (_master, F_SETFD, FD_CLOEXEC);
      fcntl (_master, F_SETFL, O_NONBLOCK);
      struct winsize size;
      memset (&size, 0, sizeof (size));
      size.ws_row = _rows;
      size.ws_col = _columns;
      ioctl (_master, TIOCSWINSZ, &size);
      /* Prepare all strings before fork; the child only calls POSIX functions.
       */
      NSMutableDictionary *env =
          [NSMutableDictionary dictionaryWithDictionary:environment];
      [env setObject:@"xterm-256color" forKey:@"TERM"];
      [env setObject:@"truecolor" forKey:@"COLORTERM"];
      [env setObject:directory forKey:@"PWD"];
      [env removeObjectForKey:@"COLUMNS"];
      [env removeObjectForKey:@"LINES"];
      char **envp = calloc ([env count] + 1, sizeof (char *));
      NSEnumerator *keys = [env keyEnumerator];
      NSString *key;
      NSUInteger index = 0;
      while ((key = [keys nextObject]) != nil)
        envp[index++] = strdup (
            [[NSString stringWithFormat:@"%@=%@", key, [env objectForKey:key]]
                UTF8String]);
      char *program = strdup ([shell fileSystemRepresentation]);
      char *cwd = strdup ([directory fileSystemRepresentation]);
      char *slave = strdup (slaveName);
      char *argv[] = { program, "-i", NULL };
      long maxFD = sysconf (_SC_OPEN_MAX);
      if (maxFD < 0)
        maxFD = 1024;
      pid_t child = fork ();
      if (child == 0)
        {
          int fd;
          unsigned int signalIndex;
          int signals[] = { SIGINT,  SIGQUIT, SIGTERM, SIGHUP,  SIGCHLD,
                            SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH };
          sigset_t mask;
          sigemptyset (&mask);
          sigprocmask (SIG_SETMASK, &mask, NULL);
          for (signalIndex = 0;
               signalIndex < sizeof (signals) / sizeof (signals[0]);
               signalIndex++)
            signal (signals[signalIndex], SIG_DFL);
          if (setsid () < 0)
            _exit (126);
          fd = open (slave, O_RDWR);
          if (fd < 0)
            _exit (126);
          ioctl (fd, TIOCSCTTY, 0);
#ifdef IUTF8
          struct termios settings;
          if (tcgetattr (fd, &settings) == 0)
            {
              settings.c_iflag |= IUTF8;
              tcsetattr (fd, TCSANOW, &settings);
            }
#endif
          dup2 (fd, 0);
          dup2 (fd, 1);
          dup2 (fd, 2);
          for (fd = 3; fd < maxFD; fd++)
            close (fd);
          if (chdir (cwd) < 0)
            {
              const char message[]
                  = "Terminal: cannot enter working directory\r\n";
              write (2, message, sizeof (message) - 1);
              _exit (126);
            }
          execve (program, argv, envp);
          {
            const char message[] = "Terminal: cannot execute shell\r\n";
            write (2, message, sizeof (message) - 1);
            _exit (127);
          }
        }
      if (child < 0)
        failure = errno;
      else
        _session = _child = child;
      for (index = 0; envp[index]; index++)
        free (envp[index]);
      free (envp);
      free (program);
      free (cwd);
      free (slave);
    }
#else
  failure = ENOSYS;
#endif
  if (failure)
    {
#ifndef _WIN32
      if (_master >= 0)
        close (_master);
#endif
      _master = -1;
      if (error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:failure
                                 userInfo:nil];
      return NO;
    }
  ASSIGN (_directory, directory);
  _ended = NO;
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
  [self clearHistory];
  [_pendingInput setLength:0];
  [_terminal reset:YES];
  [_terminal flush];
  _timer = RETAIN ([NSTimer timerWithTimeInterval:0.02
                                           target:self
                                         selector:@selector (poll:)
                                         userInfo:nil
                                          repeats:YES]);
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSDefaultRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSModalPanelRunLoopMode];
  return YES;
}

#ifndef _WIN32

+ (void)reapChild:(NSArray *)processes
{
  CREATE_AUTORELEASE_POOL (pool);
  pid_t child = [[processes objectAtIndex:0] intValue];
  pid_t foreground = [[processes objectAtIndex:1] intValue];
#ifdef __linux__
  (void)foreground;
#endif
  int status, attempts;
#ifdef __linux__
  /* Limit signals and waitpid to this terminal's session, never other windows
     or unrelated application children. The session leader is reaped last. */
  for (attempts = 0; attempts < 100; attempts++)
    {
      BOOL remaining = NO;
      DIR *directory = opendir ("/proc");
      struct dirent *entry;
      if (directory)
        {
          while ((entry = readdir (directory)))
            {
              char *end;
              long number = strtol (entry->d_name, &end, 10);
              if (*end || number <= 0 || number == child)
                continue;
              pid_t pid = (pid_t)number;
              if (getsid (pid) != child)
                continue;
              if (attempts == 0)
                kill (pid, SIGHUP);
              if (attempts >= 50)
                kill (pid, SIGKILL);
              pid_t result = waitpid (pid, &status, WNOHANG);
              if (result != pid && getsid (pid) == child)
                remaining = YES;
            }
          closedir (directory);
        }
      if (!remaining)
        break;
      if (attempts == 50 && getsid (child) == child)
        kill (child, SIGKILL);
      usleep (20000);
    }
#else
  for (attempts = 0; attempts < 50; attempts++)
    {
      if (!(foreground > 0 && foreground != child
            && getsid (foreground) == child))
        break;
      usleep (20000);
    }
  if (foreground > 0 && getsid (foreground) == child)
    kill (-foreground, SIGKILL);
#endif
  /* A shell can itself ignore HUP. waitpid is off the UI thread. */
  for (attempts = 0; attempts < 50; attempts++)
    {
      pid_t result = waitpid (child, &status, WNOHANG);
      if (result == child || (result < 0 && errno == ECHILD))
        break;
      usleep (20000);
    }
  if (attempts == 50)
    {
      if (getsid (child) == child)
        {
          kill (-child, SIGKILL);
          kill (child, SIGKILL);
        }
      while (waitpid (child, &status, 0) < 0 && errno == EINTR)
        {
        }
    }
  [cleanup_condition lock];
  cleanup_count--;
  [cleanup_condition broadcast];
  [cleanup_condition unlock];
  RELEASE (pool);
}
#endif

- (void)stop
{
  [_resizeTimer invalidate];
  DESTROY (_resizeTimer);
  _showResizeIndicator = NO;
  [_timer invalidate];
  DESTROY (_timer);
#ifndef _WIN32
  pid_t foreground = _master >= 0 ? tcgetpgrp (_master) : -1;
  if (_session > 0)
    {
      if (foreground > 0 && getsid (foreground) == _session)
        kill (-foreground, SIGHUP);
      if (getsid (_session) == _session)
        {
          kill (-_session, SIGHUP);
          kill (_session, SIGHUP);
        }
      [cleanup_condition lock];
      cleanup_count++;
      [cleanup_condition unlock];
      [NSThread
          detachNewThreadSelector:@selector (reapChild:)
                         toTarget:[self class]
                       withObject:[NSArray
                                      arrayWithObjects:
                                          [NSNumber numberWithInt:_session],
                                          [NSNumber numberWithInt:foreground],
                                          nil]];
    }
  if (_master >= 0)
    close (_master);
#endif
  _session = _child = _master = -1;
  [self updateSessionTitle];
  [_pendingInput setLength:0];
}

- (BOOL)hasActiveJobs
{
#ifndef _WIN32
  if (_master < 0 || _session <= 0)
    return NO;
  pid_t foreground = tcgetpgrp (_master);
  if (foreground > 0 && foreground != _session)
    return YES;
#ifdef __linux__
  /* exec can replace the shell without changing its process group. */
  struct stat shellInfo, processInfo;
  NSString *executable = [NSString stringWithFormat:@"/proc/%d/exe", _session];
  if (_shellPath && stat ([_shellPath fileSystemRepresentation], &shellInfo) == 0
      && stat ([executable fileSystemRepresentation], &processInfo) == 0
      && (shellInfo.st_dev != processInfo.st_dev
          || shellInfo.st_ino != processInfo.st_ino))
    return YES;
  /* Include background and stopped jobs, but not the idle login shell. */
  DIR *directory = opendir ("/proc");
  struct dirent *entry;
  if (directory)
    {
      BOOL found = NO;
      while ((entry = readdir (directory)))
        {
          char *end;
          long number = strtol (entry->d_name, &end, 10);
          if (*end == 0 && number > 0 && number != _session
              && getsid ((pid_t)number) == _session)
            {
              found = YES;
              break;
            }
        }
      closedir (directory);
      return found;
    }
#endif
#endif
  return NO;
}

- (BOOL)requiresCloseConfirmation
{
  return _confirmClose && [self hasActiveJobs];
}

- (NSString *)runningProcessName
{
#ifdef __linux__
  if (_master >= 0)
    {
      pid_t foreground = tcgetpgrp (_master);
      if (foreground > 0)
        {
          NSString *path = [NSString stringWithFormat:@"/proc/%d/comm",
                                                     (int)foreground];
          NSString *name = [NSString stringWithContentsOfFile:path
                                      encoding:NSUTF8StringEncoding error:NULL];
          return [name stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
#endif
  return nil;
}

- (void)updateSessionTitle
{
  if (!_directory)
    return;
#ifdef __linux__
  if (_child > 0)
    {
      char path[64], directory[4096];
      snprintf (path, sizeof (path), "/proc/%d/cwd", _child);
      ssize_t length = readlink (path, directory, sizeof (directory) - 1);
      if (length > 0)
        {
          directory[length] = 0;
          NSString *current = [[NSFileManager defaultManager]
              stringWithFileSystemRepresentation:directory length:length];
          if (current)
            ASSIGNCOPY (_directory, current);
        }
    }
#endif
  NSString *process = _showProcess ? [self runningProcessName] : nil;
  NSString *title = [process length]
      ? [NSString stringWithFormat:@"Prompt — %@ — %@", _directory, process]
      : [NSString stringWithFormat:@"Prompt — %@", _directory];
  if (![[[self window] title] isEqual:title])
    [[self window] setTitle:title];
}

- (void)poll:(NSTimer *)timer
{
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - _lastSessionUpdate >= 0.5)
    {
      _lastSessionUpdate = now;
      [self updateSessionTitle];
    }
  if (now - _lastBlink >= 0.5)
    {
      _lastBlink = now;
      [self advanceBlink];
    }
#ifndef _WIN32
  char buffer[8192];
  ssize_t count;
  NSUInteger total = 0;
  BOOL finished = NO;
  while (_master >= 0 && total < 262144)
    {
      count = read (_master, buffer, sizeof (buffer));
      if (count > 0)
        {
          [self consumeData:[NSData dataWithBytes:buffer length:count]];
          total += count;
        }
      else if (count < 0 && errno == EINTR)
        continue;
      else
        {
          if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK))
            finished = YES;
          break;
        }
    }
  if (!finished && [_pendingInput length])
    {
      count = write (_master, [_pendingInput bytes], [_pendingInput length]);
      if (count > 0)
        [_pendingInput replaceBytesInRange:NSMakeRange (0, count)
                                 withBytes:NULL
                                    length:0];
      else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK
               && errno != EINTR)
        finished = YES;
    }
  int status;
  if (_child > 0)
    {
      pid_t result = waitpid (_child, &status, WNOHANG);
      if (result == _child || (result < 0 && errno == ECHILD))
        {
          _child = -1;
          /* Keep draining output until EOF, including output larger than one
           * poll budget. */
          if (total == 0)
            finished = YES;
        }
    }
  if (finished)
    {
      AUTORELEASE (RETAIN (self));
      [self stop];
      _ended = YES;
      if (_closeOnExit)
        {
          [[self window] close];
          return;
        }
      [self consumeData:
                [@"\r\n[Shell exited. Press Return to start a new shell.]\r\n"
                    dataUsingEncoding:NSUTF8StringEncoding]];
    }
#endif
}

- (void)restart:(id)sender
{
  if (!_directory)
    return;
  [self stop];
  NSError *error = nil;
  if (![self startInDirectory:_directory error:&error])
    [[NSAlert alertWithError:error] runModal];
}

- (BOOL)cellAtRow:(NSInteger)row column:(int)column cell:(TerminalGlyph *)cell
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  memset (cell, 0, sizeof (*cell));
  if (row < 0 || column < 0 || column >= _columns)
    return NO;
  if (row < history)
    {
      NSData *line = [_history objectAtIndex:row];
      if ((column + 1) * sizeof (*cell) > [line length])
        return NO;
      *cell = ((const TerminalGlyph *)[line bytes])[column];
      return YES;
    }
  TerminalPosition position = { (int)(row - history), column };
  return position.row < _rows
         && [_terminal getCell:cell row:position.row column:position.col];
}

- (NSString *)screenText
{
  NSMutableString *text = [NSMutableString string];
  int row, col;
  NSInteger history = _alternateScreen ? 0 : [_history count];
  for (row = 0; row < _rows; row++)
    {
      for (col = 0; col < _columns; col++)
        {
          TerminalGlyph cell;
          if ([self cellAtRow:history + row column:col cell:&cell]
              && cell.width != 0)
            [text appendString:terminal_cell_string (&cell)];
        }
      [text appendString:@"\n"];
    }
  return text;
}

- (NSColor *)color:(TerminalColor)color
{
  if (color.kind == TerminalColorDefaultForeground)
    return _foregroundColor;
  if (color.kind == TerminalColorDefaultBackground)
    return _backgroundColor;
  color = [_terminal resolvedColor:color];
  return [NSColor colorWithCalibratedRed:color.rgb.red / 255.0
                                   green:color.rgb.green / 255.0
                                    blue:color.rgb.blue / 255.0
                                   alpha:1];
}

- (void)drawRect:(NSRect)dirty
{
  [_backgroundColor set];
  NSRectFill (dirty);
  NSInteger history = _alternateScreen ? 0 : [_history count];
  NSInteger first = history - _scrollOffset;
  NSInteger low = MIN (_selectionStart, _selectionEnd),
            high = MAX (_selectionStart, _selectionEnd);
  int row, col, pass;
  /* Paint backgrounds before glyphs so a wide glyph is not erased by its
   trailing cell. Clip each glyph to its terminal cell(s), not its font
   * advance. */
  int firstRow = MAX (0, (int)floor (NSMinY (dirty) / _cellHeight));
  int lastRow = MIN (_rows, (int)ceil (NSMaxY (dirty) / _cellHeight));
  int firstCol = MAX (
      0, (int)floor ((NSMinX (dirty) - [NSScroller scrollerWidth]) / _cellWidth)
             - 1);
  int lastCol
      = MIN (_columns, (int)ceil ((NSMaxX (dirty) - [NSScroller scrollerWidth])
                                  / _cellWidth));
  for (pass = 0; pass < 2; pass++)
    for (row = firstRow; row < lastRow; row++)
      {
        for (col = firstCol; col < lastCol; col++)
          {
            NSRect rect
                = NSMakeRect ([NSScroller scrollerWidth] + col * _cellWidth,
                              row * _cellHeight, _cellWidth, _cellHeight);
            TerminalGlyph cell;
            if (![self cellAtRow:first + row column:col cell:&cell])
              continue;
            NSRect paintRect = rect;
            if (pass == 1)
              paintRect.size.width *= MAX (1, cell.width);
            if (!NSIntersectsRect (paintRect, dirty)
                || ![self needsToDrawRect:paintRect])
              continue;
            NSColor *fg = [self color:cell.fg], *bg = [self color:cell.bg];
            if ((cell.attributes & TerminalReverse))
              {
                NSColor *swap = fg;
                fg = bg;
                bg = swap;
              }
            NSInteger position = (first + row) * _columns + col;
            if (low >= 0 && position >= low && position <= high)
              {
                bg = [NSColor selectedTextBackgroundColor];
                fg = [NSColor selectedTextColor];
              }
            if (pass == 0)
              {
                [bg set];
                NSRectFill (rect);
                continue;
              }
            if (cell.width == 0 || (cell.attributes & TerminalConceal)
                || ((cell.attributes & TerminalBlink) && !_blinkOn))
              continue;
            /* Blank cells still have backgrounds and decorations, but need no
             * glyph. */
            if ((cell.chars[0] == 0 || (cell.chars[0] == ' ' && !cell.chars[1]))
                && !(cell.attributes & TerminalUnderline) && !(cell.attributes & TerminalStrike))
              continue;
            NSFont *font = (cell.attributes & TerminalBold) ? _boldFont : _font;
            if ((cell.attributes & TerminalItalic))
              {
                NSFont *italic = [[NSFontManager sharedFontManager]
                    convertFont:font
                    toHaveTrait:NSItalicFontMask];
                if (italic)
                  font = italic;
              }
            NSMutableDictionary *attributes = [NSMutableDictionary
                dictionaryWithObjectsAndKeys:font, NSFontAttributeName, fg,
                                             NSForegroundColorAttributeName,
                                             nil];
            if ((cell.attributes & TerminalUnderline))
              [attributes
                  setObject:[NSNumber
                                numberWithInt:(cell.attributes & TerminalDoubleUnderline)
                                                  ? NSUnderlineStyleDouble
                                                  : NSUnderlineStyleSingle]
                     forKey:NSUnderlineStyleAttributeName];
            if ((cell.attributes & TerminalStrike))
              [attributes
                  setObject:[NSNumber numberWithInt:NSUnderlineStyleSingle]
                     forKey:NSStrikethroughStyleAttributeName];
            [NSGraphicsContext saveGraphicsState];
            NSRectClip (NSMakeRect (rect.origin.x, rect.origin.y,
                                    _cellWidth * MAX (1, cell.width),
                                    _cellHeight));
            [[terminal_cell_string (&cell)
                precomposedStringWithCanonicalMapping] drawAtPoint:rect.origin
                                                    withAttributes:attributes];
            [NSGraphicsContext restoreGraphicsState];
          }
      }
  BOOL cursorCanBlink = [self cursorCanBlink];
  if (_cursorVisible && !_scrollOffset && (!cursorCanBlink || _blinkOn))
    {
      TerminalPosition cursor;
      cursor = [_terminal cursorPosition];
      [_cursorColor set];
      NSInteger shape = _preferredCursorShape;
      if (shape == 0)
        shape = _cursorShape == TerminalCursorUnderline
                    ? 4
                    : (_cursorShape == TerminalCursorBar ? 3 : 1);
      NSRect rect
          = NSMakeRect ([NSScroller scrollerWidth] + cursor.col * _cellWidth,
                        cursor.row * _cellHeight, _cellWidth, _cellHeight);
      if (shape == 4)
        NSRectFill (
            NSMakeRect (rect.origin.x, NSMaxY (rect) - 2, _cellWidth, 2));
      else if (shape == 3)
        NSRectFill (NSMakeRect (rect.origin.x, rect.origin.y, 2, _cellHeight));
      else if (shape == 1)
        {
          NSRectFill (rect);
          TerminalGlyph cell;
          if ([_terminal getCell:&cell row:cursor.row column:cursor.col]
              && cell.width != 0 && !(cell.attributes & TerminalConceal))
            {
              NSColor *rgb = [_cursorColor
                  colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
              NSColor *ink
                  = ([rgb redComponent] * 0.299 + [rgb greenComponent] * 0.587 +
                     [rgb blueComponent] * 0.114)
                            > 0.5
                        ? [NSColor blackColor]
                        : [NSColor whiteColor];
              [NSGraphicsContext saveGraphicsState];
              NSRectClip (rect);
              [terminal_cell_string (&cell)
                     drawAtPoint:rect.origin
                  withAttributes:[NSDictionary
                                     dictionaryWithObjectsAndKeys:
                                         (cell.attributes & TerminalBold) ? _boldFont : _font,
                                         NSFontAttributeName, ink,
                                         NSForegroundColorAttributeName, nil]];
              [NSGraphicsContext restoreGraphicsState];
            }
        }
      else
        NSFrameRect (rect);
    }
  if (_showResizeIndicator || [self inLiveResize])
    {
      NSString *text = [NSString stringWithFormat:@"%d x %d", _columns, _rows];
      NSDictionary *attributes = [NSDictionary
          dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:14],
                                       NSFontAttributeName,
                                       [NSColor blackColor],
                                       NSForegroundColorAttributeName, nil];
      NSSize size = [text sizeWithAttributes:attributes];
      NSRect box
          = NSMakeRect (floor (NSMidX ([self bounds]) - (size.width + 24) / 2),
                        floor (NSMidY ([self bounds]) - (size.height + 16) / 2),
                        size.width + 24, size.height + 16);
      NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box
                                                           xRadius:6
                                                           yRadius:6];
      [[NSColor colorWithCalibratedRed:1 green:1 blue:0.85 alpha:1] set];
      [path fill];
      [[NSColor darkGrayColor] set];
      [path stroke];
      [text drawAtPoint:NSMakePoint (box.origin.x + 12, box.origin.y + 8)
          withAttributes:attributes];
    }
}

- (void)keyDown:(NSEvent *)event
{
  NSString *characters = [event characters];
  if (![characters length])
    return;
  unichar c = [characters characterAtIndex:0];
  if (_ended && (c == '\r' || c == '\n'))
    {
      [self restart:nil];
      return;
    }
  if (!_alternateScreen && ([event modifierFlags] & NSShiftKeyMask)
      && (c == NSPageUpFunctionKey || c == NSPageDownFunctionKey))
    {
      _scrollOffset = MIN (
          (NSInteger)[_history count],
          MAX (0, _scrollOffset + (c == NSPageUpFunctionKey ? _rows : -_rows)));
      [self updateScroller];
      [self setNeedsDisplay:YES];
      return;
    }
  BOOL redraw = _scrollOffset != 0 || _selectionStart >= 0;
  _scrollOffset = 0;
  _selectionStart = _selectionEnd = -1;
  _wheelRemainder = 0;
  [self updateScroller];
  [_terminal handleKeyEvent:event];
  if (redraw)
    [self setNeedsDisplay:YES];
  else if (!_blinkOn)
    {
      TerminalPosition cursor;
      cursor = [_terminal cursorPosition];
      [self invalidateCursorAt:cursor];
    }
  _blinkOn = YES;
  _lastBlink = [NSDate timeIntervalSinceReferenceDate];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
  if ([[self window] firstResponder] == self
      && ([event modifierFlags] & NSControlKeyMask)
      && !([event modifierFlags] & NSCommandKeyMask))
    {
      [self keyDown:event];
      return YES;
    }
  return [super performKeyEquivalent:event];
}

- (NSInteger)positionForEvent:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSInteger history = _alternateScreen ? 0 : [_history count];
  int row = MIN (_rows - 1, MAX (0, (int)(p.y / _cellHeight)));
  int col
      = MIN (_columns - 1,
             MAX (0, (int)((p.x - [NSScroller scrollerWidth]) / _cellWidth)));
  return (history - _scrollOffset + row) * _columns + col;
}

- (BOOL)reportMouse:(NSEvent *)event button:(int)button pressed:(BOOL)pressed
{
  if (!_mouseReporting || ([event modifierFlags] & NSShiftKeyMask))
    return NO;
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  [_terminal mouseRow:MIN (_rows - 1, MAX (0, (int)(p.y / _cellHeight)))
               column:MIN (_columns - 1, MAX (0, (int)((p.x -
                           [NSScroller scrollerWidth]) / _cellWidth)))
               button:button pressed:pressed modifiers:[event modifierFlags]];
  return YES;
}

- (void)mouseDown:(NSEvent *)event
{
  [[self window] makeFirstResponder:self];
  if ([self reportMouse:event button:1 pressed:YES])
    return;
  _selectionStart = _selectionEnd = [self positionForEvent:event];
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
  if ([self reportMouse:event button:0 pressed:NO])
    return;
  _selectionEnd = [self positionForEvent:event];
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
  if (![self reportMouse:event button:1 pressed:NO])
    [self copyToPasteboard:[self selectionPasteboard]];
}

- (void)rightMouseDown:(NSEvent *)event
{
  if (![self reportMouse:event button:3 pressed:YES])
    [super rightMouseDown:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
  [self reportMouse:event button:3 pressed:NO];
}

- (void)rightMouseDragged:(NSEvent *)event
{
  [self reportMouse:event button:0 pressed:NO];
}

- (void)otherMouseDown:(NSEvent *)event
{
  if (![self reportMouse:event button:2 pressed:YES])
    {
      [[self window] makeFirstResponder:self];
      [self pasteFromPasteboard:[self selectionPasteboard]];
    }
}

- (void)otherMouseUp:(NSEvent *)event
{
  [self reportMouse:event button:2 pressed:NO];
}

- (void)otherMouseDragged:(NSEvent *)event
{
  [self reportMouse:event button:0 pressed:NO];
}

- (void)mouseMoved:(NSEvent *)event
{
  [self reportMouse:event button:0 pressed:NO];
}

- (void)updateScroller
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  _scrollOffset = MIN (history, MAX (0, _scrollOffset));
  [_historyScroller
       setFloatValue:history ? 1.0 - (double)_scrollOffset / history : 1.0
      knobProportion:(double)_rows / MAX (1, history + _rows)];
  [_historyScroller setEnabled:history > 0];
}

- (void)scrollHistory:(NSScroller *)sender
{
  NSInteger history = _alternateScreen ? 0 : [_history count];
  switch ([sender hitPart])
    {
    case NSScrollerDecrementLine:
      _scrollOffset++;
      break;
    case NSScrollerIncrementLine:
      _scrollOffset--;
      break;
    case NSScrollerDecrementPage:
      _scrollOffset += MAX (1, _rows - 1);
      break;
    case NSScrollerIncrementPage:
      _scrollOffset -= MAX (1, _rows - 1);
      break;
    default:
      _scrollOffset = lround ((1.0 - [sender doubleValue]) * history);
      break;
    }
  _wheelRemainder = 0;
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event
{
  if ([event deltaY] == 0)
    return;
  if ([self reportMouse:event button:[event deltaY] > 0 ? 4 : 5 pressed:YES])
    return;
  if (_alternateScreen)
    return;
  /* Preserve fractional trackpad movement instead of truncating every event. */
  _wheelRemainder += [event deltaY] * 3;
  NSInteger lines = (NSInteger)_wheelRemainder;
  _wheelRemainder -= lines;
  _scrollOffset += lines;
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (void)selectAll:(id)sender
{
  _selectionStart = 0;
  _selectionEnd
      = ((_alternateScreen ? 0 : [_history count]) + _rows) * _columns - 1;
  [self setNeedsDisplay:YES];
}

- (NSPasteboard *)pasteboard
{
  return [NSPasteboard generalPasteboard];
}

- (NSPasteboard *)selectionPasteboard
{
  return [NSPasteboard pasteboardWithName:@"Selection"];
}

- (void)copy:(id)sender
{
  [self copyToPasteboard:[self pasteboard]];
}

- (void)copyToPasteboard:(NSPasteboard *)pasteboard
{
  if (_selectionStart < 0)
    return;
  NSInteger start = MIN (_selectionStart, _selectionEnd),
            end = MAX (_selectionStart, _selectionEnd);
  NSMutableString *result = [NSMutableString string],
                  *line = [NSMutableString string];
  NSInteger i;
  for (i = start; i <= end; i++)
    {
      TerminalGlyph cell;
      if ([self cellAtRow:i / _columns column:i % _columns cell:&cell]
          && cell.width != 0 && !(cell.attributes & TerminalWrapPadding))
        [line appendString:terminal_cell_string (&cell)];
      if (i % _columns == _columns - 1 || i == end)
        {
          TerminalGlyph last;
          BOOL wrapped = [self cellAtRow:i / _columns column:_columns - 1
                                    cell:&last]
                         && (last.attributes & TerminalSoftWrap);
          if (!wrapped || i == end)
            while ([line hasSuffix:@" "])
              [line deleteCharactersInRange:NSMakeRange ([line length] - 1, 1)];
          [result appendString:line];
          [line setString:@""];
          if (i != end && !wrapped)
            [result appendString:@"\n"];
        }
    }
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType]
                     owner:nil];
  [pasteboard setString:result forType:NSStringPboardType];
}

- (void)paste:(id)sender
{
  [self pasteFromPasteboard:[self pasteboard]];
}

- (void)pasteFromPasteboard:(NSPasteboard *)pasteboard
{
  NSString *text = [pasteboard stringForType:NSStringPboardType];
  if (![text length])
    return;
  /* Strip escape bytes so pasted text cannot terminate bracketed-paste mode. */
  text = [text stringByReplacingOccurrencesOfString:@"\033" withString:@""];
  text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
  [_terminal sendString:text];
  _scrollOffset = 0;
  _wheelRemainder = 0;
  [self updateScroller];
  [self setNeedsDisplay:YES];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
  NSMenu *menu = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Terminal"]);
  NSArray *titles = [NSArray arrayWithObjects:@"Copy", @"Paste", @"Select All",
                                              @"Restart Terminal", nil];
  SEL actions[] = { @selector (copy:), @selector (paste:),
                    @selector (selectAll:), @selector (restart:) };
  NSUInteger i;
  for (i = 0; i < [titles count]; i++)
    {
      NSMenuItem *item =
          [[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i]
                                     action:actions[i]
                              keyEquivalent:@""];
      [item setTarget:self];
      [menu addItem:item];
      RELEASE (item);
    }
  return menu;
}

@end
