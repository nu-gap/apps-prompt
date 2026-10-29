/*
 * This file is distributed under the GNU General Public License, version 3
 * or later. It comes WITHOUT ANY WARRANTY, including MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See <https://www.gnu.org/licenses/>.
 */

/*
   Project: Ycode

   Copyright (C) 2025 Free Software Foundation

   Author: Gregory Casamento

   Created: 2025-01-15

   This application is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This application is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
*/

/* Adapted for independent Terminal regression tests. */
#import <AppKit/AppKit.h>
#import "TerminalView.h"
#import "TerminalPreferences.h"
#import "AppController.h"
#ifdef TERMINAL_X11_RESIZE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#import <GNUstepGUI/GSDisplayServer.h>
#endif
#include <math.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
static NSUInteger failures, checks;
static void
test_assert (BOOL ok, NSString *message)
{
  checks++;
  if (!ok)
    failures++;
  NSLog (@"%@: %@", ok ? @"PASS" : @"FAIL", message);
}

@interface TerminalView (Testing)

- (BOOL)cellAtRow:(NSInteger)row
           column:(int)column
             cell:(TerminalGlyph *)cell;

- (void)queueBytes:(const char *)bytes length:(size_t)length;

- (NSPasteboard *)pasteboard;
- (NSPasteboard *)selectionPasteboard;
- (void)advanceBlink;

@end

@interface TerminalTestView : TerminalView
{
  NSMutableData *_captured;
}

- (NSData *)takeOutput;

@end
@implementation TerminalTestView

- (NSPasteboard *)pasteboard
{
  return [NSPasteboard pasteboardWithName:@"TerminalTerminalRegression"];
}

- (NSPasteboard *)selectionPasteboard
{
  return [NSPasteboard pasteboardWithName:@"TerminalSelectionRegression"];
}

- (void)queueBytes:(const char *)bytes length:(size_t)length
{
  if (!_captured)
    _captured = [[NSMutableData alloc] init];
  [_captured appendBytes:bytes length:length];
  [super queueBytes:bytes length:length];
}

- (NSData *)takeOutput
{
  NSData *result = [NSData dataWithData:_captured ? _captured : [NSData data]];
  [_captured setLength:0];
  return result;
}

- (void)dealloc
{
  RELEASE (_captured);
  DEALLOC;
}

@end

static void
terminal_feed (TerminalView *view, NSString *text)
{
  [view consumeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

static BOOL
terminal_wait (TerminalView *view, NSString *text)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0)
    {
      if ([[view screenText] rangeOfString:text].location != NSNotFound)
        return YES;
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
  return NO;
}

static void
test_terminal (NSString *temporaryDirectory)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedTerminalPreferences
      = RETAIN ([defaults objectForKey:@"TerminalSettings"]);
  [TerminalPreferences resetTerminalPreferences];

  /* Verify the application-owned parser's Prompt integration independently. */
  TerminalTestView *engineView = [[TerminalTestView alloc]
      initWithFrame:NSMakeRect (0, 0, 500, 240)];
  TerminalParser_VT100 *engine = [engineView valueForKey:@"_terminal"];
  terminal_feed (engineView, @"\033[?1004h");
  [engine focusChanged:YES];
  [engine focusChanged:NO];
  test_assert ([[engineView takeOutput] isEqual:
      [@"\033[I\033[O" dataUsingEncoding:NSUTF8StringEncoding]],
      @"Focus reporting follows the requested terminal mode");
  terminal_feed (engineView, @"\033[6 q");
  test_assert ([[engineView valueForKey:@"_cursorShape"] intValue]
                   == TerminalCursorBar
               && ![[engineView valueForKey:@"_cursorBlink"] boolValue],
               @"DECSCUSR selects a steady bar cursor");
  terminal_feed (engineView, @"\033[3 q");
  test_assert ([[engineView valueForKey:@"_cursorShape"] intValue]
                   == TerminalCursorUnderline
               && [[engineView valueForKey:@"_cursorBlink"] boolValue],
               @"DECSCUSR selects a blinking underline cursor");
  terminal_feed (engineView, @"\033[4:2mD\033[24mS");
  TerminalGlyph engineCell;
  [engineView cellAtRow:0 column:0 cell:&engineCell];
  test_assert ((engineCell.attributes & TerminalDoubleUnderline) != 0,
               @"Colon-form SGR retains double underline");
  [engineView cellAtRow:0 column:1 cell:&engineCell];
  test_assert (!(engineCell.attributes
                  & (TerminalUnderline | TerminalDoubleUnderline)),
               @"SGR 24 clears both underline styles");
  terminal_feed (engineView, @"\033[?1002h\033[?1006h");
  [engine mouseRow:1 column:2 button:1 pressed:YES modifiers:0];
  [engine mouseRow:2 column:3 button:0 pressed:NO modifiers:0];
  [engine mouseRow:2 column:3 button:1 pressed:NO modifiers:0];
  test_assert ([[engineView takeOutput] isEqual:
      [@"\033[<0;3;2M\033[<32;4;3M\033[<0;4;3m"
          dataUsingEncoding:NSUTF8StringEncoding]],
      @"SGR mouse mode reports press, drag, and release");
  terminal_feed (engineView, @"\033c");
  [engine focusChanged:YES];
  [engine mouseRow:3 column:4 button:1 pressed:YES modifiers:0];
  test_assert ([[engineView takeOutput] length] == 0
               && ![[engineView valueForKey:@"_mouseReporting"] boolValue],
               @"Hard reset disables focus and mouse reporting");
  terminal_feed (engineView, @"\033[?1049h\033cprimary");
  test_assert (![[engineView valueForKey:@"_alternateScreen"] boolValue]
               && [[engineView screenText] hasPrefix:@"primary"],
               @"Hard reset returns to the primary screen");
  RELEASE (engineView);

  TerminalTestView *view =
      [[TerminalTestView alloc] initWithFrame:NSMakeRect (0, 0, 800, 400)];
  test_assert (![view isRunning],
               @"Constructing a terminal does not start a shell");
  /* Exercise parser mode forwarding, including ignored OSC titles. */
  terminal_feed (view, @"\033[?25l\033[?12l\033[4 q\033[?1000h");
  test_assert (![[view valueForKey:@"_cursorVisible"] boolValue]
                   && ![[view valueForKey:@"_cursorBlink"] boolValue]
                   && [[view valueForKey:@"_cursorShape"] intValue]
                          == TerminalCursorUnderline
                   && [[view valueForKey:@"_mouseReporting"] boolValue],
               @"Parser forwards cursor and mouse modes");
  terminal_feed (view, @"\033]2;ignored title\007\033[?25h\033[?12h\033[2 q\033[?1000l");
  test_assert ([[view valueForKey:@"_cursorVisible"] boolValue]
                   && [[view valueForKey:@"_cursorBlink"] boolValue] == NO
                   && [[view valueForKey:@"_cursorShape"] intValue]
                          == TerminalCursorBlock
                   && ![[view valueForKey:@"_mouseReporting"] boolValue],
               @"Parser ignores OSC titles and restores modes");
  terminal_feed (view, @"abc\rZ\033[2;4HQ\033[1;2H\033[K");
  TerminalGlyph cell;
  [view cellAtRow:0 column:0 cell:&cell];
  test_assert (cell.chars[0] == 'Z',
               @"Terminal carriage return overwrites the current line");
  [view cellAtRow:0 column:1 cell:&cell];
  test_assert (cell.chars[0] == 0, @"Erase-to-end clears terminal cells");
  [view cellAtRow:1 column:3 cell:&cell];
  test_assert (cell.chars[0] == 'Q',
               @"ANSI absolute cursor addressing uses rows and columns");
  terminal_feed (view, @"\033[H\033[38;2;12;");
  terminal_feed (view, @"34;56;48;5;196;1;4mC");
  [view cellAtRow:0 column:0 cell:&cell];
  test_assert (
      cell.chars[0] == 'C' && cell.fg.rgb.red == 12 && cell.fg.rgb.green == 34
          && cell.fg.rgb.blue == 56 && cell.bg.index == 196
          && (cell.attributes & TerminalBold) && (cell.attributes & TerminalUnderline),
      @"Fragmented SGR supports truecolor, indexed color, bold, and underline");
  terminal_feed (view, @"\033[0m\033[2J\033[Hnormal\033[?1049h\033[Halternate");
  test_assert ([[view screenText] hasPrefix:@"alternate"],
               @"Full-screen applications get an alternate screen");
  terminal_feed (view, @"\033[?1049l");
  test_assert ([[view screenText] hasPrefix:@"normal"],
               @"Leaving alternate screen restores shell contents");
  terminal_feed (view, @"\033[2J\033[H\033(0lqk\033(B");
  test_assert ([[view screenText] hasPrefix:@"┌─┐"],
               @"DEC line drawing character set renders box characters");
  terminal_feed (view, @"\033[2J\033[H");
  NSData *unicode = [@"é中é" dataUsingEncoding:NSUTF8StringEncoding];
  NSUInteger byte;
  for (byte = 0; byte < [unicode length]; byte++)
    [view consumeData:[unicode subdataWithRange:NSMakeRange (byte, 1)]];
  test_assert (
      [[view screenText] hasPrefix:@"é中é"],
      @"Split UTF-8, wide characters, and combining marks survive reads");
  terminal_feed (view, @"\033[2J\033[H1\r\n2\r\n3\r\n4\033[2;3r\033[3;1H\n");
  [view cellAtRow:0 column:0 cell:&cell];
  test_assert (cell.chars[0] == '1',
               @"Scrolling margins preserve the line above the region");
  [view cellAtRow:1 column:0 cell:&cell];
  test_assert (cell.chars[0] == '3',
               @"Scrolling margins move only the selected region");
  terminal_feed (view, @"\033[r\033[2J\033[HABC\033[1;2H\033[@X");
  test_assert ([[view screenText] hasPrefix:@"AXBC"],
               @"Insert-character shifts terminal cells");
  terminal_feed (view, @"\033[1;2H\033[P");
  test_assert ([[view screenText] hasPrefix:@"ABC"],
               @"Delete-character shifts terminal cells back");
  terminal_feed (view, @"\033]0;untrusted title\007\033[2J\033[Hsafe");
  test_assert (
      [[view screenText] hasPrefix:@"safe"],
      @"OSC title bytes are consumed without printing escape payloads");
  int row;
  for (row = 0; row < 100; row++)
    terminal_feed (view, @"history\r\n");
  test_assert ([[view valueForKey:@"_history"] count] > 0,
               @"Terminal retains bounded scrollback");
  NSScroller *historyScroller = [view valueForKey:@"_historyScroller"];
  test_assert (
      [historyScroller knobProportion] < 1.0 &&
          [historyScroller doubleValue] == 1.0,
      @"Terminal scrollbar follows live output when history is available");
  [historyScroller setDoubleValue:0];
  [historyScroller sendAction:[historyScroller action]
                           to:[historyScroller target]];
  test_assert (
      [[view valueForKey:@"_scrollOffset"] integerValue] ==
          [[view valueForKey:@"_history"] count],
      @"Dragging the scrollbar to the top reaches the oldest retained output");
  NSInteger previousOffset = [[view valueForKey:@"_scrollOffset"] integerValue];
  terminal_feed (view, @"new output\r\n");
  test_assert ([[view valueForKey:@"_scrollOffset"] integerValue]
                   == previousOffset + 1,
               @"New output preserves the position while browsing history");
  [historyScroller setDoubleValue:1];
  [historyScroller sendAction:[historyScroller action]
                           to:[historyScroller target]];
  test_assert ([[view valueForKey:@"_scrollOffset"] integerValue] == 0,
               @"Dragging the scrollbar to the bottom returns to live output");
  terminal_feed (view, @"\033[?1049h");
  test_assert ([historyScroller knobProportion] == 1.0,
               @"Alternate screens do not expose shell history");
  terminal_feed (view, @"\033[?1049l");
  test_assert (
      [historyScroller knobProportion] < 1.0,
      @"Returning from an alternate screen restores the history scrollbar");
  terminal_feed (view, @"\033[3J\033[2J\033[H");
  test_assert (
      [[view valueForKey:@"_history"] count] == 0 &&
          [historyScroller knobProportion] == 1.0,
      @"Erase-scrollback clears retained history and disables the scrollbar");
  [view takeOutput];
  terminal_feed (view, @"\033[4;9H\033[6n");
  test_assert (
      [[view takeOutput]
          isEqual:[@"\033[4;9R" dataUsingEncoding:NSUTF8StringEncoding]],
      @"Device status query returns the current terminal cursor position");
  unichar arrow = NSUpArrowFunctionKey;
  NSString *up = [NSString stringWithCharacters:&arrow length:1];
  NSEvent *upEvent = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                    characters:up
                   charactersIgnoringModifiers:up
                                     isARepeat:NO
                                       keyCode:0];
  [view keyDown:upEvent];
  test_assert ([[view takeOutput]
                   isEqual:[@"\033[A" dataUsingEncoding:NSUTF8StringEncoding]],
               @"Normal cursor keys send CSI sequences");
  terminal_feed (view, @"\033[?1h");
  [view keyDown:upEvent];
  test_assert ([[view takeOutput]
                   isEqual:[@"\033OA" dataUsingEncoding:NSUTF8StringEncoding]],
               @"Application cursor mode switches keyboard sequences");
  terminal_feed (view, @"\033[?1l\033[?2004h");
  NSPasteboard *pasteboard = [view pasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType]
                     owner:nil];
  [pasteboard setString:@"first\nsecond" forType:NSStringPboardType];
  [view paste:nil];
  test_assert (
      [[view takeOutput] isEqual:[@"\033[200~first\rsecond\033[201~"
                                     dataUsingEncoding:NSUTF8StringEncoding]],
      @"Bracketed paste wraps multiline clipboard text for supporting "
      @"applications");
  terminal_feed (view, @"\033[?2004l\033[2J\033[Hcopy me");
  [view selectAll:nil];
  [view copy:nil];
  test_assert (
      [[pasteboard stringForType:NSStringPboardType] hasPrefix:@"copy me\n"],
      @"Terminal selection copies text without escape sequences");
  [view setValue:[NSNumber numberWithInt:-1] forKey:@"_selectionStart"];
  [view setValue:[NSNumber numberWithInt:-1] forKey:@"_selectionEnd"];
  terminal_feed (view, @"\033[2J\033[H");

  /* Selection must survive leaving less's alternate screen. */
  terminal_feed (view, @"\033[?1049h2d9716c");
  [view setValue:[NSNumber numberWithInt:0] forKey:@"_selectionStart"];
  [view setValue:[NSNumber numberWithInt:6] forKey:@"_selectionEnd"];
  [view mouseUp:nil];
  terminal_feed (view, @"\033[?1049l");
  [view otherMouseDown:nil];
  test_assert ([[view takeOutput] isEqual:
      [@"2d9716c" dataUsingEncoding:NSUTF8StringEncoding]],
      @"Middle paste retains selection after pager exit");
  test_assert ([[pasteboard stringForType:NSStringPboardType]
      hasPrefix:@"copy me\n"], @"Mouse selection leaves clipboard intact");
  [[view selectionPasteboard] setString:@"external\nselection"
                              forType:NSStringPboardType];
  terminal_feed (view, @"\033[?2004h");
  [view otherMouseDown:nil];
  test_assert ([[view takeOutput] isEqual:
      [@"\033[200~external\rselection\033[201~"
          dataUsingEncoding:NSUTF8StringEncoding]],
      @"Middle paste reads selection pasteboard and honors bracketed paste");
  terminal_feed (view, @"\033[?2004l");

  TerminalTestView *flow = [[TerminalTestView alloc]
      initWithFrame:NSMakeRect (0, 0, 500, 240)];
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  terminal_feed (flow, @"abcdefghijklmnopqr\r\nSECOND\r\n$ ");
  [flow setFrameSize:[flow contentSizeForColumns:10 rows:6]];
  test_assert ([[flow screenText] hasPrefix:@"abcdefghij\nklmnopqr"],
      @"Narrowing reflows existing output instead of clipping it");
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  test_assert ([[flow screenText] hasPrefix:@"abcdefghijklmnopqr"],
      @"Widening rejoins soft wraps");
  terminal_feed (flow, @"X");
  test_assert ([[flow screenText] rangeOfString:@"$ X"].location != NSNotFound,
      @"Reflow preserves the insertion cursor and explicit newlines");
  terminal_feed (flow, @"\033c1234567890abcdefghijK\r\nnext\r\n");
  [flow setFrameSize:[flow contentSizeForColumns:5 rows:3]];
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  test_assert ([[flow screenText] rangeOfString:@"1234567890abcdefghij"].location
      != NSNotFound, @"Reflow restores wrapped output from history");
  terminal_feed (flow, @"\033c123456789界Z");
  [flow setFrameSize:[flow contentSizeForColumns:10 rows:6]];
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  test_assert ([[flow screenText] hasPrefix:@"123456789界Z"],
      @"Wide glyph padding does not become text when reflowing");
  terminal_feed (flow, @"\033cabcdefghijklmnopqr\r\n$ ");
  terminal_feed (flow, @"\033[?1049hFULL SCREEN");
  [flow setFrameSize:[flow contentSizeForColumns:10 rows:6]];
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  terminal_feed (flow, @"\033[?1049lX");
  test_assert ([[flow screenText] hasPrefix:@"abcdefghijklmnopqr"]
      && [[flow screenText] rangeOfString:@"$ X"].location != NSNotFound,
      @"Resizing a pager preserves hidden primary output and cursor");
  terminal_feed (flow, @"\033c1234567890");
  [flow setFrameSize:[flow contentSizeForColumns:5 rows:6]];
  terminal_feed (flow, @"Z");
  [flow setFrameSize:[flow contentSizeForColumns:20 rows:6]];
  test_assert ([[flow screenText] hasPrefix:@"1234567890Z"],
      @"Writing after reflow at the right edge preserves pending wrap");
  terminal_feed (flow, @"\033cword next");
  [flow setFrameSize:[flow contentSizeForColumns:5 rows:6]];
  [flow selectAll:nil];
  [flow copy:nil];
  test_assert ([[[flow pasteboard] stringForType:NSStringPboardType]
      hasPrefix:@"word next\n"],
      @"Copy joins soft wraps while preserving spaces at wrap boundaries");
  RELEASE (flow);

  /* Exercise AppKit drawing, including wide glyphs, in a real window. */
  NSWindow *preview = [[NSWindow alloc]
      initWithContentRect:NSMakeRect (20, 20, 800, 400)
                styleMask:NSTitledWindowMask | NSClosableWindowMask
                          | NSResizableWindowMask
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [preview setReleasedWhenClosed:NO];
  [preview setTitle:@"Terminal Terminal"];
  [preview setContentView:view];
  [preview makeKeyAndOrderFront:nil];
  terminal_feed (view,
                 @"Terminal Terminal — ANSI / VT100\r\n\r\n\033[1mBold\033[0m  "
                 @"\033[4mUnderline\033[0m  \033[3mItalic\033[0m\r\n");
  for (row = 0; row < 16; row++)
    terminal_feed (
        view, [NSString stringWithFormat:@"\033[48;5;%dm  %2d  ", row, row]);
  terminal_feed (
      view, @"\033[0m\r\n\r\n\033[38;2;90;200;255mTruecolor\033[0m  UTF-8: "
            @"café 中 é\r\n\r\n\033(0lqqqqqqqqqqqqqqqqqqqqk\r\nx\033(B ANSI "
            @"line drawing  \033(0x\r\nmqqqqqqqqqqqqqqqqqqqqj\033(B\r\n\r\n$ ");
  [preview display];
  [view viewWillStartLiveResize];
  [preview setContentSize:[view contentSizeForColumns:92 rows:30]];
  test_assert ([[view valueForKey:@"_columns"] intValue] == 92 &&
                   [[view valueForKey:@"_rows"] intValue] == 30,
               @"Resize indicator uses the updated terminal grid");
#ifdef TERMINAL_X11_RESIZE
  GSDisplayServer *server = GSServerForWindow (preview);
  if ([server respondsToSelector:@selector (xDisplayRootWindow)])
    {
      Display *display = (Display *)[server serverDevice];
      Window xid = (Window)[preview windowRef];
      XSizeHints hints;
      XWindowAttributes dimensions;
      long supplied;
      BOOL gotHints = XGetWMNormalHints (display, xid, &hints, &supplied)
                      && XGetWindowAttributes (display, xid, &dimensions);
      test_assert (
          gotHints && (hints.flags & PBaseSize) && (hints.flags & PResizeInc)
              && hints.width_inc > 0 && hints.height_inc > 0
              && (dimensions.width - hints.base_width) / hints.width_inc == 92
              && (dimensions.height - hints.base_height) / hints.height_inc
                     == 30,
          @"Window manager resize readout reports character columns and rows");
    }
#endif
  NSBitmapImageRep *resizeBitmap =
      [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:resizeBitmap];
  NSData *duringResize =
      [resizeBitmap representationUsingType:NSPNGFileType
                                 properties:[NSDictionary dictionary]];
  [duringResize
      writeToFile:[temporaryDirectory
                      stringByAppendingPathComponent:@"resize-indicator.png"]
       atomically:YES];
  [view viewDidEndLiveResize];
  [preview display];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:resizeBitmap];
  test_assert (
      ![duringResize
          isEqual:[resizeBitmap
                      representationUsingType:NSPNGFileType
                                   properties:[NSDictionary dictionary]]],
      @"Ending live resize removes the rendered size indicator");

  if ([[[NSProcessInfo processInfo] arguments]
          containsObject:@"--terminal-preview"])
    {
      NSBitmapImageRep *bitmap =
          [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
      [view cacheDisplayInRect:[view bounds] toBitmapImageRep:bitmap];
      [[bitmap representationUsingType:NSPNGFileType
                            properties:[NSDictionary dictionary]]
          writeToFile:@"/tmp/ycode-terminal-preview.png"
           atomically:YES];
    }
#ifndef _WIN32
  NSString *directory = [temporaryDirectory
      stringByAppendingPathComponent:@"Terminal Folder With Spaces"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  NSError *error = nil;
  test_assert ([view startInDirectory:directory error:&error] && error == nil,
               @"Launch interactive shell on a PTY");
  if ([view isRunning])
    {
      int child = [[view valueForKey:@"_child"] intValue];
      test_assert ([view startInDirectory:@"/" error:&error] &&
                       [[view valueForKey:@"_child"] intValue] == child,
                   @"Repeated opening preserves the terminal shell");
      [view sendData:[@"stty -echo; printf '\\033[2J\\033[H'; test -t 0 && "
                      @"printf '%s%s\\n' TERMINAL_ISTTY _YES; pwd\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (terminal_wait (view, @"TERMINAL_ISTTY_YES")
                       && terminal_wait (view, directory),
                   @"Shell has a controlling terminal and starts in the "
                   @"terminal directory with spaces");
      [view sendData:[@"printf '%s%s\\n' TERMINAL_TERM_ \"$TERM\"\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (terminal_wait (view, @"TERMINAL_TERM_xterm-256color"),
                   @"Shell advertises the implemented terminal protocol");
      [view setFrameSize:NSMakeSize (640, 320)];
      NSString *dimensions =
          [NSString stringWithFormat:@"%@ %@", [view valueForKey:@"_rows"],
                                     [view valueForKey:@"_columns"]];
      [view sendData:[@"stty size\r" dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (
          terminal_wait (view, dimensions),
          @"Resizing propagates row and column counts through the PTY");
      /* A foreground job must receive Ctrl-C through the PTY, not terminate
       * Terminal. */
      [view sendData:[@"sleep 30\r" dataUsingEncoding:NSUTF8StringEncoding]];
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
      test_assert ([view hasActiveJobs] && [view requiresCloseConfirmation],
                   @"Foreground job requires close confirmation");
      test_assert ([[view runningProcessName] isEqual:@"sleep"],
                   @"Foreground process name is detected");
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
      test_assert ([[preview title] rangeOfString:@" — sleep"].location != NSNotFound,
                   @"Window title includes the running process");
      [TerminalPreferences setTerminalShowProcess:NO];
      test_assert ([[preview title] rangeOfString:@" — sleep"].location == NSNotFound,
                   @"Process title preference applies immediately");
      [TerminalPreferences setTerminalShowProcess:YES];
      [TerminalPreferences setTerminalConfirmClose:NO];
      test_assert (![view requiresCloseConfirmation] && [view hasActiveJobs],
                   @"Confirmation preference can disable the warning");
      [TerminalPreferences setTerminalConfirmClose:YES];
      NSEvent *interrupt = [NSEvent keyEventWithType:NSKeyDown
                                            location:NSZeroPoint
                                       modifierFlags:NSControlKeyMask
                                           timestamp:0
                                        windowNumber:[preview windowNumber]
                                             context:nil
                                          characters:@"\003"
                         charactersIgnoringModifiers:@"c"
                                           isARepeat:NO
                                             keyCode:0];
      [view keyDown:interrupt];
      [view sendData:[@"printf '%s%s\\n' TERMINAL_INTERRUPT _OK\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (terminal_wait (view, @"TERMINAL_INTERRUPT_OK") &&
                       [view isRunning],
                   @"Ctrl-C interrupts the job and preserves the shell");
      test_assert (![view hasActiveJobs], @"Idle shell does not require a warning");
      [view sendData:[@"sleep 30 & printf 'BACKGROUND_READY\\n'\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (terminal_wait (view, @"BACKGROUND_READY") && [view hasActiveJobs],
                   @"Background jobs require close confirmation");
      [view sendData:[@"kill $!; wait; cd /tmp; printf 'DIRECTORY_READY\\n'\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
      terminal_wait (view, @"DIRECTORY_READY");
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
      test_assert ([[preview title] hasPrefix:@"Prompt — /tmp — "],
                   @"Title follows the shell working directory");
      [view sendData:[[NSString stringWithFormat:@"cd '%@'\r", directory]
                         dataUsingEncoding:NSUTF8StringEncoding]];
      if ([[NSFileManager defaultManager]
              isExecutableFileAtPath:@"/usr/bin/vim"])
        {
          [view sendData:
                    [@"/usr/bin/vim -Nu NONE -i NONE -n 'terminal editor.txt'\r"
                        dataUsingEncoding:NSUTF8StringEncoding]];
          NSDate *editorDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
          while (![[view valueForKey:@"_alternateScreen"] boolValue] &&
                 [editorDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
          test_assert ([[view valueForKey:@"_alternateScreen"] boolValue],
                       @"Vim enters its full-screen terminal mode");
          [view sendData:[@"iTerminal terminal editor test\033:wq\r"
                             dataUsingEncoding:NSUTF8StringEncoding]];
          editorDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
          while ([[view valueForKey:@"_alternateScreen"] boolValue] &&
                 [editorDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
          test_assert (
              ![[view valueForKey:@"_alternateScreen"] boolValue] &&
                  [[NSString stringWithContentsOfFile:
                                 [directory stringByAppendingPathComponent:
                                                @"terminal editor.txt"]
                                             encoding:NSUTF8StringEncoding
                                                error:NULL]
                      isEqual:@"Terminal terminal editor test\n"],
              @"An interactive Vim session edits, saves, exits, and restores "
              @"the shell screen");
        }
      [view sendData:[@"exit\r" dataUsingEncoding:NSUTF8StringEncoding]];
      test_assert (terminal_wait (view, @"Shell exited.") && ![view isRunning],
                   @"Shell exit drains output and releases the PTY");
      [view restart:nil];
      test_assert ([view isRunning], @"Exited shells can be restarted");
      child = [[view valueForKey:@"_child"] intValue];
      [preview close];
      test_assert (![view isRunning],
                   @"Closing the terminal window hangs up its terminal");
      NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
      while (kill (child, 0) == 0 && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
      test_assert (kill (child, 0) < 0 && errno == ESRCH,
                   @"Terminal cleanup reaps the shell without zombies");
    }
  error = nil;
  test_assert (
      ![view
          startInDirectory:[directory stringByAppendingPathComponent:@"missing"]
                     error:&error]
          && error != nil,
      @"Invalid terminal directories produce a useful error");
#endif
  [preview close];
  RELEASE (preview);
  RELEASE (view);

  if (savedTerminalPreferences)
    [defaults setObject:savedTerminalPreferences forKey:@"TerminalSettings"];
  else
    [defaults removeObjectForKey:@"TerminalSettings"];
  RELEASE (savedTerminalPreferences);
}

static void
pump (double seconds)
{
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL
color_matches (NSColor *color, double r, double g, double b)
{
  color = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return color && fabs ([color redComponent] - r) < .012
         && fabs ([color greenComponent] - g) < .012
         && fabs ([color blueComponent] - b) < .012;
}

@interface FractionalWheel : NSObject

@end
@implementation FractionalWheel
- (CGFloat)deltaY
{
  return 0.1;
}

- (NSUInteger)modifierFlags
{
  return NSShiftKeyMask;
}

@end

static void
test_preferences_and_rendering (NSString *directory)
{
  AppController *app = [[AppController alloc] init];
  [app buildMenus];
  [app showPreferences:nil];
  TerminalView *terminal = [app openDirectory:directory];
  RETAIN (terminal);
  [terminal sendData:[@"stty -echo; stty size\r"
      dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (terminal, @"25 80"),
               @"Mapped terminal reports the configured 80 by 25 PTY size");
  test_assert ([[terminal valueForKey:@"_columns"] intValue] == 80 &&
                   [[terminal valueForKey:@"_rows"] intValue] == 25,
               @"New terminal opens with an 80 by 25 grid");
  test_assert (NSMinX ([[terminal valueForKey:@"_historyScroller"] frame]) == 0,
               @"History scroller occupies the left edge");
  int child = [[terminal valueForKey:@"_child"] intValue];
  NSMenuItem *toggle = AUTORELEASE ([[NSMenuItem alloc]
      initWithTitle:@""
             action:@selector (toggleTerminal:)
      keyEquivalent:@""]);
  [app validateMenuItem:toggle];
  test_assert ([[toggle title] isEqual:@"Close Terminal"],
               @"Visible terminal menu offers Close Terminal");
  [app toggleTerminal:toggle];
  test_assert ([[toggle title] isEqual:@"Open Terminal"]
                   && ![[terminal window] isVisible] && [terminal isRunning],
               @"Close Terminal hides the window and preserves its session");
  [app toggleTerminal:toggle];
  test_assert (
      [[toggle title] isEqual:@"Close Terminal"] &&
          [[terminal window] isVisible] &&
          [[terminal valueForKey:@"_child"] intValue] == child,
      @"Open Terminal restores the same shell and updates its menu title");
  NSButton *button = [app valueForKey:@"_fontButton"];
  [button performClick:nil];
  pump (.1);
  NSFontManager *manager = [NSFontManager sharedFontManager];
  NSFontPanel *fontPanel = [manager fontPanel:YES];
  [fontPanel
      setPanelFont:[manager convertFont:[TerminalPreferences terminalFont]
                                 toSize:20]
        isMultiple:NO];
  [fontPanel makeKeyAndOrderFront:nil];
  [manager modifyFontViaPanel:fontPanel];
  test_assert ([[TerminalPreferences terminalFont] pointSize] == 20 &&
                   [[terminal valueForKey:@"_font"] pointSize] == 20,
               @"Native Fonts panel action updates and persists the live font");
  [fontPanel orderOut:nil];
  test_assert ([[terminal valueForKey:@"_child"] intValue] == child,
               @"Font change preserves shell PID");
  [terminal sendData:[@"stty -echo; stty size\r"
                         dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (
      terminal_wait (
          terminal,
          [NSString stringWithFormat:@"%@ %@", [terminal valueForKey:@"_rows"],
                                     [terminal valueForKey:@"_columns"]]),
      @"Font change updates real PTY dimensions");
  [terminal stop];
  [TerminalView waitForChildCleanup];
  NSColorWell *fg = [app valueForKey:@"_foreground"],
              *bg = [app valueForKey:@"_background"],
              *cursor = [app valueForKey:@"_cursor"];
  [fg activate:YES];
  [[NSColorPanel sharedColorPanel] setColor:[NSColor colorWithCalibratedRed:.2
                                                                      green:.8
                                                                       blue:.6
                                                                      alpha:1]];
  [fg deactivate];
  [bg activate:YES];
  [[NSColorPanel sharedColorPanel] setColor:[NSColor colorWithCalibratedRed:.1
                                                                      green:.15
                                                                       blue:.2
                                                                      alpha:1]];
  [bg deactivate];
  [cursor activate:YES];
  [[NSColorPanel sharedColorPanel] setColor:[NSColor greenColor]];
  [cursor deactivate];
  [[NSColorPanel sharedColorPanel] orderOut:nil];
  test_assert (
      color_matches ([TerminalPreferences terminalForegroundColor], .2, .8, .6)
          && color_matches ([TerminalPreferences terminalBackgroundColor], .1,
                            .15, .2)
          && color_matches ([TerminalPreferences terminalCursorColor], 0, 1, 0),
      @"Native Color panel actions persist all three colors");
  terminal_feed (terminal, @"\033c\033[?25hM\r\n");
  NSPopUpButton *shape = [app valueForKey:@"_shape"];
  NSUInteger w = [[terminal valueForKey:@"_cellWidth"] unsignedIntegerValue];
  NSUInteger h = [[terminal valueForKey:@"_cellHeight"] unsignedIntegerValue];
  int s;
  for (s = 0; s <= 4; s++)
    {
      [shape selectItemAtIndex:s];
      [shape sendAction:[shape action] to:[shape target]];
      [[terminal window] display];
      NSBitmapImageRep *bitmap =
          [terminal bitmapImageRepForCachingDisplayInRect:[terminal bounds]];
      [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
      NSUInteger x, y, cursorPixels = 0, textPixels = 0;
      for (y = 0; y < h * 2; y++)
        for (x = 0; x < w; x++)
          {
            NSColor *pixel =
                [bitmap colorAtX:x + (NSUInteger)[NSScroller scrollerWidth]
                               y:y];
            if (color_matches (pixel, 0, 1, 0))
              cursorPixels++;
            if (color_matches (pixel, .2, .8, .6))
              textPixels++;
          }
      NSUInteger expected = s <= 1   ? w * h
                            : s == 2 ? 2 * (w + h) - 4
                            : s == 3 ? 2 * h
                                     : 2 * w;
      test_assert (
          cursorPixels == expected,
          [NSString stringWithFormat:
                        @"Rendered cursor shape %d: %lu pixels, expected %lu",
                        s, (unsigned long)cursorPixels,
                        (unsigned long)expected]);
      test_assert (
          textPixels > 0
              && color_matches ([bitmap colorAtX:400 y:200], .1, .15, .2),
          @"Rendered default text/background match Color panel choices");
      [[bitmap representationUsingType:NSPNGFileType
                            properties:[NSDictionary dictionary]]
          writeToFile:[directory
                          stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"cursor-%d.png", s]]
           atomically:YES];
    }
  [TerminalPreferences setTerminalCursorShape:1];
  terminal_feed (terminal, @"\033[H\033[31mM\033[0m\r");
  NSBitmapImageRep *bitmap =
      [terminal bitmapImageRepForCachingDisplayInRect:[terminal bounds]];
  [[terminal window] display];
  [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
  NSUInteger x, y, ink = 0;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++)
      if (color_matches (
              [bitmap colorAtX:x + (NSUInteger)[NSScroller scrollerWidth] y:y],
              0, 0, 0))
        ink++;
  [[bitmap representationUsingType:NSPNGFileType
                        properties:[NSDictionary dictionary]]
      writeToFile:[directory stringByAppendingPathComponent:@"filled-ink.png"]
       atomically:YES];
  test_assert (ink > 0,
               @"Filled block redraws its character in contrasting ink");
  terminal_feed (terminal, @"\033[?25l\033[H\033[31mM\033[0m");
  [[terminal window] display];
  [terminal cacheDisplayInRect:[terminal bounds] toBitmapImageRep:bitmap];
  NSUInteger red = 0;
  for (y = 0; y < h; y++)
    for (x = 0; x < w; x++)
      {
        NSColor *pixel = [[bitmap
            colorAtX:x + (NSUInteger)[NSScroller scrollerWidth]
                   y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        if ([pixel redComponent] > .5 && [pixel greenComponent] < .2)
          red++;
      }
  test_assert (
      red > 0,
      @"Explicit ANSI foreground remains red after default color changes");
  int i;
  for (i = 0; i < 100; i++)
    terminal_feed (terminal, @"history\r\n");
  FractionalWheel *wheel = [[FractionalWheel alloc] init];
  for (i = 0; i < 4; i++)
    [terminal scrollWheel:(NSEvent *)wheel];
  RELEASE (wheel);
  test_assert ([[terminal valueForKey:@"_scrollOffset"] intValue] == 1,
               @"Fractional trackpad events accumulate into a line");
  NSTextField *history = [app valueForKey:@"_history"];
  [history setStringValue:@"0"];
  [history sendAction:[history action] to:[history target]];
  test_assert (
      [[terminal valueForKey:@"_history"] count] == 0,
      @"History preference zero discards existing history immediately");
  [history setStringValue:@"50001"];
  [history sendAction:[history action] to:[history target]];
  test_assert ([TerminalPreferences terminalScrollbackLines] == 0,
               @"Out of range history input rejected");
  [history setStringValue:@"50000"];
  [history sendAction:[history action] to:[history target]];
  test_assert ([TerminalPreferences terminalScrollbackLines] == 50000,
               @"Maximum history setting accepted");
  NSButton *bell = [app valueForKey:@"_bell"],
           *blink = [app valueForKey:@"_blink"];
  [bell setState:NSOffState];
  [blink setState:NSOffState];
  [app changeSettings:bell];
  TerminalView *fresh =
      [[TerminalView alloc] initWithFrame:NSMakeRect (0, 0, 600, 300)];
  test_assert ([[fresh valueForKey:@"_font"] pointSize] == 20
                   && ![[fresh valueForKey:@"_audibleBell"] boolValue]
                   && ![[fresh valueForKey:@"_allowCursorBlink"] boolValue],
               @"New terminals inherit persisted font and bell/blink settings");
  RELEASE (fresh);
  NSTextField *columns = [app valueForKey:@"_columns"],
              *rows = [app valueForKey:@"_rows"];
  [columns setStringValue:@"100"];
  [rows setStringValue:@"35"];
  [app changeDimensions:columns];
  NSSize previousSize = [[terminal window] frame].size;
  TerminalView *sized = [app openDirectory:directory];
  [sized sendData:[@"stty -echo; stty size\r"
      dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (sized, @"35 100"),
               @"Mapped terminal reports custom dimensions through stty");
  test_assert ([[sized valueForKey:@"_columns"] intValue] == 100 &&
                   [[sized valueForKey:@"_rows"] intValue] == 35,
               @"New sessions use the configured character columns and rows");
  test_assert (NSEqualSizes (previousSize, [[terminal window] frame].size),
               @"Window-size preferences preserve existing sessions");
  [[sized window] close];
  [columns setStringValue:@"100.5"];
  [app changeDimensions:columns];
  [rows setStringValue:@"1001"];
  [app changeDimensions:rows];
  test_assert (
      [columns integerValue] == 100 && [rows integerValue] == 35,
      @"Fractional and out-of-range dimensions restore the saved values");
  [[app valueForKey:@"_closeOnExit"] performClick:nil];
  [app showPreferences:nil];
  NSView *preferencesView = [[app valueForKey:@"_preferences"] contentView];
  [[app valueForKey:@"_preferences"] display];
  NSBitmapImageRep *preferencesBitmap = [preferencesView
      bitmapImageRepForCachingDisplayInRect:[preferencesView bounds]];
  [preferencesView cacheDisplayInRect:[preferencesView bounds]
                     toBitmapImageRep:preferencesBitmap];
  [[preferencesBitmap representationUsingType:NSPNGFileType
                                   properties:[NSDictionary dictionary]]
      writeToFile:[directory stringByAppendingPathComponent:@"preferences.png"]
       atomically:YES];
  NSString *executable =
      [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
  if (![executable isAbsolutePath])
    executable = [[[NSFileManager defaultManager] currentDirectoryPath]
        stringByAppendingPathComponent:executable];
  const char *program = [executable fileSystemRepresentation];
  pid_t reader = fork ();
  if (reader == 0)
    {
      execl (program, program, "--read-preferences", NULL);
      _exit (127);
    }
  int result = -1;
  if (reader > 0)
    while (waitpid (reader, &result, 0) < 0 && errno == EINTR)
      {
      }
  test_assert (result == 0, @"A separate process reloads persisted font, "
                            @"colors, history and bell preferences");
  [app restoreDefaults:nil];
  test_assert ([TerminalPreferences terminalColumns] == 80 &&
                   [TerminalPreferences terminalRows] == 25,
               @"Restore Defaults resets new-window dimensions to 80 by 25");
  test_assert (
      [[terminal valueForKey:@"_font"] pointSize] == 13 &&
          [TerminalPreferences terminalScrollbackLines] == 5000
          && color_matches ([TerminalPreferences terminalCursorColor], 1, 0, 0),
      @"Restore Defaults updates existing views and restores red cursor");
  [[terminal window] close];
  RELEASE (terminal);
  [[app valueForKey:@"_preferences"] orderOut:nil];
  RELEASE (app);
}

static void
test_initial_size_and_programs (NSString *directory)
{
  TerminalTestView *view =
      [[TerminalTestView alloc] initWithFrame:NSMakeRect (0, 0, 803, 407)];
  NSError *error = nil;
  test_assert ([view startInDirectory:directory error:&error],
               @"Start independent PTY dimension test");
  struct winsize size;
  memset (&size, 0, sizeof (size));
  ioctl ([[view valueForKey:@"_master"] intValue], TIOCGWINSZ, &size);
  test_assert (
      size.ws_row
              == (int)(407 / [[view valueForKey:@"_cellHeight"] doubleValue])
          && size.ws_col
                 == (int)((803 - [NSScroller scrollerWidth]) /
                          [[view valueForKey:@"_cellWidth"] doubleValue]),
      @"Initial PTY dimensions use actual bounds, font metrics and scrollbar "
      @"width");
  [view
      sendData:
          [@"stty -echo; trap 'echo RESIZE_SIGNAL' WINCH; echo READY_FOR_SIZE\r"
              dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (view, @"READY_FOR_SIZE"),
               @"Interactive shell ready for SIGWINCH");
  [view setFrameSize:NSMakeSize (650, 350)];
  test_assert (terminal_wait (view, @"RESIZE_SIGNAL"),
               @"Window resize signals foreground process");
  [view
      sendData:[@"seq 1 100 | less\r" dataUsingEncoding:NSUTF8StringEncoding]];
  pump (.5);
  test_assert ([[view valueForKey:@"_alternateScreen"] boolValue],
               @"Real less uses alternate screen");
  [view sendData:[@"q" dataUsingEncoding:NSUTF8StringEncoding]];
  pump (.3);
  test_assert (![[view valueForKey:@"_alternateScreen"] boolValue],
               @"less exits back to normal screen");
  [view sendData:[@"top -d 1\r" dataUsingEncoding:NSUTF8StringEncoding]];
  pump (1.2);
  test_assert ([[view screenText] rangeOfString:@"PID"].location != NSNotFound,
               @"Real interactive top renders process display");
  [view setFrameSize:NSMakeSize (750, 400)];
  pump (.3);
  [view sendData:[@"q" dataUsingEncoding:NSUTF8StringEncoding]];
  pump (.3);
  [view sendData:[@"printf 'AFTER_%s\\n' TOP\r"
                     dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (view, @"AFTER_TOP"),
               @"top survives resize and exits to usable shell");
  [view sendData:[@"python3 -c 'import signal,time; "
                  @"signal.signal(signal.SIGHUP,signal.SIG_IGN); "
                  @"print(\"STUBBORN_JOB\",flush=True); time.sleep(60)'\r"
                     dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (view, @"STUBBORN_JOB"),
               @"Start foreground job that ignores hangup");
  int master = [[view valueForKey:@"_master"] intValue];
  pid_t child = [[view valueForKey:@"_child"] intValue],
        foreground = tcgetpgrp (master);
  NSDate *start = [NSDate date];
  [view stop];
  test_assert (-[start timeIntervalSinceNow] < .1,
               @"Session close does not block on stubborn child");
  [TerminalView waitForChildCleanup];
  test_assert (kill (child, 0) < 0 && errno == ESRCH,
               @"Stubborn session shell reaped");
  /* The Linux subreaper must collect the orphaned job, not leave it to PID 1.
   */
  NSString *stat = [NSString
      stringWithContentsOfFile:[NSString stringWithFormat:@"/proc/%d/stat",
                                                          foreground]
                      encoding:NSUTF8StringEncoding
                         error:NULL];
  test_assert (
      !stat,
      @"Hangup-ignoring foreground job is killed and reaped without zombies");
  [view restart:nil];
  [view sendData:[@"stty -echo; python3 -c 'import tty,time; tty.setraw(0); "
                  @"print(\"SLOW_READER\",flush=True); time.sleep(60)'\r"
                     dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (view, @"SLOW_READER"),
               @"Start a PTY program that stops reading input");
  NSMutableData *largePaste = [NSMutableData dataWithLength:1024 * 1024];
  memset ([largePaste mutableBytes], 'a', [largePaste length]);
  start = [NSDate date];
  [view sendData:largePaste];
  pump (.25);
  [view setFrameSize:NSMakeSize (780, 420)];
  test_assert (-[start timeIntervalSinceNow] < 1 &&
                   [[view valueForKey:@"_pendingInput"] length] > 0,
               @"A blocked PTY reader leaves input queued while the GUI run "
               @"loop and resize remain responsive");
  [view stop];
  [TerminalView waitForChildCleanup];
  RELEASE (view);
}

static NSEvent *
key_event (unichar key, NSUInteger modifiers)
{
  NSString *characters = [NSString stringWithCharacters:&key length:1];
  return [NSEvent keyEventWithType:NSKeyDown
                          location:NSZeroPoint
                     modifierFlags:modifiers
                         timestamp:0
                      windowNumber:0
                           context:nil
                        characters:characters
       charactersIgnoringModifiers:characters
                         isARepeat:NO
                           keyCode:0];
}

static void
test_input_and_history (void)
{
  TerminalTestView *view =
      [[TerminalTestView alloc] initWithFrame:NSMakeRect (0, 0, 500, 200)];
  terminal_feed (view, @"\033=");
  [view keyDown:key_event ('1', NSNumericPadKeyMask)];
  test_assert ([[view takeOutput]
                   isEqual:[@"\033Oq" dataUsingEncoding:NSUTF8StringEncoding]],
               @"Application keypad sends SS3 keypad sequence");
  terminal_feed (view, @"\033>");
  [view keyDown:key_event (NSF5FunctionKey, 0)];
  test_assert (
      [[view takeOutput]
          isEqual:[@"\033[15~" dataUsingEncoding:NSUTF8StringEncoding]],
      @"F5 sends xterm function key sequence");
  terminal_feed (view, @"\033[?1000h\033[?1006h");
  NSEvent *mouse = [NSEvent
      mouseEventWithType:NSLeftMouseDown
                location:NSMakePoint ([NSScroller scrollerWidth] + 3, 3)
           modifierFlags:0
               timestamp:0
            windowNumber:0
                 context:nil
             eventNumber:1
              clickCount:1
                pressure:1];
  [view mouseDown:mouse];
  NSString *report
      = AUTORELEASE ([[NSString alloc] initWithData:[view takeOutput]
                                           encoding:NSUTF8StringEncoding]);
  test_assert ([report hasPrefix:@"\033[<0;"] && [report hasSuffix:@"M"],
               @"Mouse reporting emits SGR button coordinates");
  mouse = [NSEvent
      mouseEventWithType:NSLeftMouseDown
                location:NSMakePoint ([NSScroller scrollerWidth] + 3, 3)
           modifierFlags:NSShiftKeyMask
               timestamp:0
            windowNumber:0
                 context:nil
             eventNumber:2
              clickCount:1
                pressure:1];
  [view mouseDown:mouse];
  test_assert (
      [[view takeOutput] length] == 0,
      @"Shift bypasses application mouse reporting for local selection");
  terminal_feed (view, @"\033[?1000l");
  int i;
  for (i = 0; i < 5100; i++)
    terminal_feed (view, @"retained line\r\n");
  test_assert (
      [[view valueForKey:@"_history"] count] == 5000,
      @"Default scrollback retains exactly 5,000 lines under sustained output");
  [view keyDown:key_event (NSPageUpFunctionKey, NSShiftKeyMask)];
  test_assert ([[view valueForKey:@"_scrollOffset"] intValue] > 0,
               @"Shift-Page Up scrolls locally");
  [view keyDown:key_event ('x', 0)];
  test_assert ([[view valueForKey:@"_scrollOffset"] intValue] == 0,
               @"Typing returns to the live prompt");
  [view keyDown:key_event (NSPageUpFunctionKey, NSShiftKeyMask)];
  [[view pasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType]
                            owner:nil];
  [[view pasteboard] setString:@"paste" forType:NSStringPboardType];
  [view paste:nil];
  test_assert ([[view valueForKey:@"_scrollOffset"] intValue] == 0,
               @"Pasting returns to the live prompt");
  terminal_feed (view, @"\033[?1049h");
  for (i = 0; i < 100; i++)
    terminal_feed (view, @"alternate scroll\r\n");
  terminal_feed (view, @"\033[?1049l");
  test_assert ([[view valueForKey:@"_history"] count] == 5000,
               @"Alternate screen scrolling leaves shell history intact");
  RELEASE (view);
}

/* Exercise cursor painting without starting a shell or a polling timer. */
@interface CursorTestView : TerminalView
{
@public
  NSUInteger fullInvalidations, partialInvalidations;
}

@end
@implementation CursorTestView
- (BOOL)isRunning
{
  return YES;
}

- (void)setNeedsDisplay:(BOOL)flag
{
  if (flag)
    fullInvalidations++;
  [super setNeedsDisplay:flag];
}

- (void)setNeedsDisplayInRect:(NSRect)rect
{
  partialInvalidations++;
  [super setNeedsDisplayInRect:rect];
}

@end

static BOOL
cursor_pixel_visible (TerminalView *view)
{
  [view setNeedsDisplay:YES];
  [[view window] display];
  NSBitmapImageRep *bitmap =
      [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:bitmap];
  return color_matches (
      [bitmap colorAtX:(NSUInteger)[NSScroller scrollerWidth] + 2 y:2], 1, 0,
      0);
}

static NSData *
rendered_pixels (TerminalView *view)
{
  [view lockFocus];
  NSBitmapImageRep *bitmap = AUTORELEASE (
      [[NSBitmapImageRep alloc] initWithFocusedViewRect:[view bounds]]);
  [view unlockFocus];
  return [bitmap representationUsingType:NSPNGFileType
                              properties:[NSDictionary dictionary]];
}

static void
test_active_cursor (void)
{
  test_assert ([TerminalPreferences terminalCursorBlink],
               @"Cursor blinking is enabled by default");
  NSWindow *windows[2];
  CursorTestView *views[2];
  int i;
  for (i = 0; i < 2; i++)
    {
      windows[i] = [[NSWindow alloc]
          initWithContentRect:NSMakeRect (40 + i * 40, 40, 320, 180)
                    styleMask:NSTitledWindowMask
                      backing:NSBackingStoreBuffered
                        defer:NO];
      [windows[i] setReleasedWhenClosed:NO];
      views[i] =
          [[CursorTestView alloc] initWithFrame:NSMakeRect (0, 0, 320, 180)];
      [windows[i] setContentView:views[i]];
      [windows[i] makeKeyAndOrderFront:nil];
      [windows[i] makeFirstResponder:views[i]];
    }
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  views[1]->fullInvalidations = views[1]->partialInvalidations = 0;
  [views[0] advanceBlink];
  [views[1] advanceBlink];
  test_assert (views[0]->fullInvalidations == 0
                   && views[0]->partialInvalidations == 0,
               @"Inactive cursor blink causes no repaint");
  test_assert (views[1]->fullInvalidations == 0
                   && views[1]->partialInvalidations > 0,
               @"Active cursor blink repaints only its cells");
  views[1]->fullInvalidations = views[1]->partialInvalidations = 0;
  terminal_feed (views[1], @"x\b \b");
  test_assert (views[1]->fullInvalidations == 0
                   && views[1]->partialInvalidations > 0,
               @"Text and cursor updates request partial redraws");
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  [views[1] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  test_assert (
      cursor_pixel_visible (views[0]) && !cursor_pixel_visible (views[1]),
      @"Only the active terminal hides its cursor during the blink off phase");
  [windows[0] makeKeyAndOrderFront:nil];
  test_assert (cursor_pixel_visible (views[0])
                   && cursor_pixel_visible (views[1]),
               @"Switching active windows immediately restores both cursors");
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  [views[1] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  test_assert (!cursor_pixel_visible (views[0])
                   && cursor_pixel_visible (views[1]),
               @"Blinking follows the newly active terminal");
  [TerminalPreferences setTerminalCursorBlink:NO];
  [views[0] setValue:[NSNumber numberWithBool:NO] forKey:@"_blinkOn"];
  test_assert (cursor_pixel_visible (views[0]),
               @"Disabling cursor blink keeps the active cursor steady");
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  [views[0] advanceBlink];
  test_assert (views[0]->fullInvalidations == 0
                   && views[0]->partialInvalidations == 0,
               @"Disabled cursor blink causes no repaint");
  terminal_feed (views[0], @"\033[5mX\033[0m");
  views[0]->fullInvalidations = views[0]->partialInvalidations = 0;
  [views[0] advanceBlink];
  test_assert (
      views[0]->fullInvalidations == 0 && views[0]->partialInvalidations > 0,
      @"ANSI blinking text still repaints with cursor blinking disabled");
  terminal_feed (views[0], @"\033[2J\033[H");
  [TerminalPreferences setTerminalCursorBlink:YES];
  terminal_feed (views[0], @"\033[?25l");
  test_assert (!cursor_pixel_visible (views[0]),
               @"Application-requested hidden cursor remains hidden");
  NSArray *updates =
      [NSArray arrayWithObjects:@"\033[?25hhello", @"\rH", @"\033[2;2H中é",
                                @"\033[2;3HX", @"\033[3;1H\033[4;41m   \033[0m",
                                @"\033[3;2H\033[K", @"\033[?1049hother screen",
                                @"\033[?1049l", @"\033[2J\033[H", nil];
  {
    NSEnumerator *enumerator = [updates objectEnumerator];
    NSString *update;
    while ((update = [enumerator nextObject]) != nil)
      {
        terminal_feed (views[0], update);
        [views[0] displayIfNeeded];
        NSData *partial = AUTORELEASE ([rendered_pixels (views[0]) copy]);
        [views[0] setNeedsDisplay:YES];
        [views[0] displayIfNeeded];
        test_assert ([partial isEqual:rendered_pixels (views[0])],
                     @"Incremental painting matches a complete repaint (text, "
                     @"wide glyphs, decorations, alternate screen)");
      }
  }
  for (i = 0; i < 2; i++)
    {
      [windows[i] close];
      RELEASE (views[i]);
      RELEASE (windows[i]);
    }
}

static void
test_profiles (NSString *directory)
{
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences resetTerminalPreferences];
  [TerminalPreferences setTerminalScrollbackLines:1234];
  AppController *app = [[AppController alloc] init];
  TerminalView *original = [app openDirectory:directory];
  pid_t pid = [[original valueForKey:@"_child"] intValue];
  [app showPreferences:nil];
  [[app valueForKey:@"_profileName"] setStringValue:@"Night"];
  [app saveProfileCopy:nil];
  test_assert ([[TerminalPreferences selectedProfileName] isEqual:@"Night"] &&
                   [TerminalPreferences terminalScrollbackLines] == 1234,
               @"Save Copy selects an independent copy of existing settings");
  [TerminalPreferences setTerminalCursorColor:[NSColor blueColor]];
  [TerminalPreferences setTerminalAudibleBell:NO];
  [TerminalPreferences setTerminalColumns:92 rows:31];
  test_assert (
      [[original profileName] isEqual:@"Default"] &&
          [[original valueForKey:@"_audibleBell"] boolValue]
          && color_matches ([original valueForKey:@"_cursorColor"], 1, 0, 0),
      @"Editing another profile leaves existing terminals unchanged");
  [app makeDefaultProfile:nil];
  TerminalView *night = [app openDirectory:directory];
  test_assert ([[night profileName] isEqual:@"Night"]
                   && ![[night valueForKey:@"_audibleBell"] boolValue] &&
                   [[night valueForKey:@"_columns"] intValue] == 92 &&
                   [[night valueForKey:@"_rows"] intValue] == 31,
               @"New windows use the default profile and its grid dimensions");
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences setTerminalAudibleBell:NO];
  [TerminalPreferences selectProfile:@"Night"];
  [TerminalPreferences setTerminalAudibleBell:YES];
  test_assert (
      ![[original valueForKey:@"_audibleBell"] boolValue] &&
          [[night valueForKey:@"_audibleBell"] boolValue],
      @"Live profile edits update only windows assigned to that profile");
  [original setProfileName:@"Night"];
  test_assert (
      [[original valueForKey:@"_child"] intValue] == pid && [original isRunning]
          && color_matches ([original valueForKey:@"_cursorColor"], 0, 0, 1),
      @"Applying a profile preserves the running shell");
  [[app valueForKey:@"_profiles"] selectItemWithTitle:@"Default"];
  [app selectProfile:nil];
  [app applyProfile:nil];
  test_assert ([[night profileName] isEqual:@"Default"] &&
                   [[original profileName] isEqual:@"Night"] &&
                   [night isRunning],
               @"Apply to Current Terminal targets only the most recently "
               @"active session");
  [app newTerminalWithProfile:nil];
  NSWindow *selectedWindow = [app valueForKey:@"_lastTerminalWindow"];
  test_assert ([[(TerminalView *)[selectedWindow contentView] profileName]
                   isEqual:@"Default"]
                   &&
                   [[TerminalPreferences defaultProfileName] isEqual:@"Night"],
               @"Open New Terminal uses the selected profile without changing "
               @"the default");
  [selectedWindow close];
  [night setProfileName:@"Night"];
  [[app valueForKey:@"_profiles"] selectItemWithTitle:@"Night"];
  [app selectProfile:nil];
  [[app valueForKey:@"_profileName"] setStringValue:@"Evening"];
  [app renameProfile:nil];
  test_assert (
      [[original profileName] isEqual:@"Evening"] &&
          [[night profileName] isEqual:@"Evening"] &&
          [[TerminalPreferences defaultProfileName] isEqual:@"Evening"],
      @"Renaming a profile preserves window assignments and the default");
  test_assert (
      ![TerminalPreferences duplicateSelectedProfileWithName:@"default"]
          && ![TerminalPreferences duplicateSelectedProfileWithName:@"  "]
          && ![TerminalPreferences renameSelectedProfile:@"Default"],
      @"Invalid and duplicate names cannot overwrite profiles");
  NSString *program = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
  if (![program isAbsolutePath])
    program = [[[NSFileManager defaultManager] currentDirectoryPath]
        stringByAppendingPathComponent:program];
  pid_t reader = fork ();
  if (reader == 0)
    {
      execl ([program fileSystemRepresentation],
             [program fileSystemRepresentation], "--read-profiles", NULL);
      _exit (127);
    }
  int result = -1;
  if (reader > 0)
    while (waitpid (reader, &result, 0) < 0 && errno == EINTR)
      {
      }
  test_assert (result == 0, @"A separate process reloads named profiles, "
                            @"selection, default and independent settings");
  [TerminalPreferences resetTerminalPreferences];
  TerminalPreferences *base = AUTORELEASE (
      [[TerminalPreferences alloc] initWithProfileName:@"Default"]);
  test_assert ([TerminalPreferences terminalScrollbackLines] == 5000 &&
                   [base terminalScrollbackLines] == 1234,
               @"Restore Defaults resets only the selected profile");
  test_assert (
      [TerminalPreferences deleteSelectedProfile] &&
          [[original profileName] isEqual:@"Default"] &&
          [[night profileName] isEqual:@"Default"] &&
          [[TerminalPreferences defaultProfileName] isEqual:@"Default"] &&
          [original isRunning],
      @"Deleting a profile falls back to Default without ending sessions");
  test_assert (![TerminalPreferences deleteSelectedProfile]
                   && ![TerminalPreferences renameSelectedProfile:@"Other"],
               @"The built-in Default profile remains available");
  [[original window] close];
  [[night window] close];
  [[app valueForKey:@"_preferences"] orderOut:nil];
  RELEASE (app);
}

static void
test_close_on_exit (NSString *directory)
{
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences resetTerminalPreferences];
  AppController *app = [[AppController alloc] init];
  [app showPreferences:nil];
  TerminalView *kept = RETAIN ([app openDirectory:directory]);
  test_assert (![TerminalPreferences terminalCloseOnExit],
               @"Shell exit keeps windows open by default");
  [kept sendData:[@"exit\r" dataUsingEncoding:NSUTF8StringEncoding]];
  test_assert (terminal_wait (kept, @"Shell exited.") &&
                   [[kept window] isVisible],
               @"Disabled close-on-exit preserves output and the window");
  NSButton *closeOnExit = [app valueForKey:@"_closeOnExit"];
  [closeOnExit performClick:nil];
  test_assert ([TerminalPreferences terminalCloseOnExit],
               @"Preferences checkbox enables close-on-exit");
  [TerminalPreferences duplicateSelectedProfileWithName:@"Keep Open"];
  [TerminalPreferences setTerminalCloseOnExit:NO];
  TerminalPreferences *base = AUTORELEASE (
      [[TerminalPreferences alloc] initWithProfileName:@"Default"]);
  test_assert ([base terminalCloseOnExit]
                   && ![TerminalPreferences terminalCloseOnExit],
               @"Copied profiles can independently control close-on-exit");
  [kept setProfileName:@"Keep Open"];
  [kept restart:nil];
  TerminalView *closing = RETAIN ([app openDirectory:directory]);
  NSWindow *window = RETAIN ([closing window]);
  [closing sendData:[@"exec /bin/sh -c 'echo EXIT_MARKER; exit 7'\r"
                        dataUsingEncoding:NSUTF8StringEncoding]];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while ([window isVisible] && [deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
  test_assert (![window isVisible] && ![closing isRunning] &&
                   [[closing screenText] rangeOfString:@"EXIT_MARKER"].location
                       != NSNotFound,
               @"Enabled close-on-exit closes an exec process with nonzero "
               @"status after draining output");
  test_assert ([kept isRunning] && [[kept window] isVisible],
               @"Automatic closure preserves other sessions");
  RELEASE (window);
  RELEASE (closing);
  [[kept window] close];
  RELEASE (kept);
  [TerminalPreferences deleteSelectedProfile];
  [app restoreDefaults:nil];
  test_assert (![TerminalPreferences terminalCloseOnExit] &&
                   [closeOnExit state] == NSOffState,
               @"Restore Defaults disables automatic closing and refreshes the "
               @"checkbox");
  [[app valueForKey:@"_preferences"] orderOut:nil];
  RELEASE (app);
}

@interface AlertAnswer : NSObject

+ (void)answer:(NSTimer *)timer;

@end

@implementation AlertAnswer

+ (void)answer:(NSTimer *)timer
{
  NSMutableArray *pending = [NSMutableArray arrayWithObject:
      [[NSApp modalWindow] contentView]];
  while ([pending count])
    {
      NSView *view = AUTORELEASE (RETAIN ([pending lastObject]));
      [pending removeLastObject];
      if ([view isKindOfClass:[NSButton class]])
        {
          NSString *title = [(NSButton *)view title];
          BOOL cancel = [[timer userInfo] integerValue] == NSAlertDefaultReturn;
          if ((cancel && [title isEqual:@"Cancel"])
              || (!cancel && ([title isEqual:@"Quit"]
                              || [title isEqual:@"Close Session"])))
            {
              [(NSButton *)view performClick:nil];
              [NSApp postEvent:[NSEvent otherEventWithType:NSApplicationDefined
                  location:NSZeroPoint modifierFlags:0 timestamp:0
                  windowNumber:0 context:nil subtype:0 data1:0 data2:0]
                  atStart:NO];
              return;
            }
        }
      [pending addObjectsFromArray:[view subviews]];
    }
}

@end

static void
answer_next_alert (NSInteger answer)
{
  NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 target:[AlertAnswer class]
                           selector:@selector (answer:)
                           userInfo:[NSNumber numberWithInteger:answer]
                            repeats:NO];
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
}

static void
test_close_confirmation (NSString *directory)
{
  [TerminalPreferences selectProfile:@"Default"];
  [TerminalPreferences resetTerminalPreferences];
  AppController *app = [[AppController alloc] init];
  TerminalView *view = RETAIN ([app openDirectory:directory]);
  NSWindow *window = RETAIN ([view window]);
  [view sendData:[@"sleep 60\r" dataUsingEncoding:NSUTF8StringEncoding]];
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
  answer_next_alert (NSAlertDefaultReturn);
  [window performClose:nil];
  test_assert ([window isVisible] && [view hasActiveJobs],
               @"Canceling the close alert preserves the window and job");
  answer_next_alert (NSAlertDefaultReturn);
  test_assert ([app applicationShouldTerminate:NSApp] == NSTerminateCancel,
               @"Canceling Quit preserves running sessions");
  answer_next_alert (NSAlertAlternateReturn);
  test_assert ([app applicationShouldTerminate:NSApp] == NSTerminateNow,
               @"Quit proceeds when explicitly confirmed");
  answer_next_alert (NSAlertAlternateReturn);
  [window performClose:nil];
  test_assert (![window isVisible] && ![view isRunning],
               @"Confirming Close Session stops the session");
  RELEASE (window);
  RELEASE (view);
  RELEASE (app);
}

int
main (int argc, const char **argv)
{
  CREATE_AUTORELEASE_POOL (pool);
  [NSApplication sharedApplication];
  [NSApp finishLaunching];
  [NSApp activateIgnoringOtherApps:YES];
  if ([[[NSProcessInfo processInfo] arguments]
          containsObject:@"--read-preferences"])
    {
      BOOL ok = [[TerminalPreferences terminalFont] pointSize] == 20 &&
                [TerminalPreferences terminalScrollbackLines] == 50000 &&
                [TerminalPreferences terminalColumns] == 100 &&
                [TerminalPreferences terminalRows] == 35
                && ![TerminalPreferences terminalAudibleBell]
                && ![TerminalPreferences terminalCursorBlink] &&
                [TerminalPreferences terminalCloseOnExit]
                && color_matches ([TerminalPreferences terminalForegroundColor],
                                  .2, .8, .6);
      RELEASE (pool);
      return ok ? 0 : 1;
    }
  if ([[[NSProcessInfo processInfo] arguments]
          containsObject:@"--read-profiles"])
    {
      TerminalPreferences *base = AUTORELEASE (
          [[TerminalPreferences alloc] initWithProfileName:@"Default"]);
      BOOL ok =
          [[TerminalPreferences defaultProfileName] isEqual:@"Evening"] &&
          [[TerminalPreferences selectedProfileName] isEqual:@"Evening"] &&
          [TerminalPreferences terminalColumns] == 92 &&
          [base terminalColumns] == 80
          && color_matches ([TerminalPreferences terminalCursorColor], 0, 0, 1)
          && color_matches ([base terminalCursorColor], 1, 0, 0);
      RELEASE (pool);
      return ok ? 0 : 1;
    }
  NSString *directory =
      [NSString stringWithFormat:@"/tmp/terminal-tests-%d", getpid ()];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *savedProfiles = [NSMutableDictionary dictionary];
  NSArray *profileKeys =
      [NSArray arrayWithObjects:@"TerminalProfiles", @"TerminalSelectedProfile",
                                @"TerminalDefaultProfile", nil];
  {
    NSEnumerator *enumerator = [profileKeys objectEnumerator];
    NSString *key;
    while ((key = [enumerator nextObject]) != nil)
      {
        id value = [defaults objectForKey:key];
        if (value)
          [savedProfiles setObject:value forKey:key];
        [defaults removeObjectForKey:key];
      }
  }
  id saved = RETAIN ([defaults objectForKey:@"TerminalSettings"]);
  [defaults
      setObject:[NSDictionary
                    dictionaryWithObjectsAndKeys:@"bad", @"fontSize",
                                                 @"no-font", @"fontName",
                                                 @"bad", @"foreground",
                                                 [NSNumber numberWithInt:-1],
                                                 @"scrollbackLines", nil]
         forKey:@"TerminalSettings"];
  test_assert ([[TerminalPreferences terminalFont] pointSize] == 13 &&
                   [TerminalPreferences terminalScrollbackLines] == 5000,
               @"Corrupt saved settings fall back safely");
  [TerminalPreferences resetTerminalPreferences];
  test_active_cursor ();
  test_terminal (directory);
  test_initial_size_and_programs (directory);
  test_input_and_history ();
  test_preferences_and_rendering (directory);
  test_profiles (directory);
  test_close_on_exit (directory);
  test_close_confirmation (directory);
  [TerminalView waitForChildCleanup];
  if (saved)
    [defaults setObject:saved forKey:@"TerminalSettings"];
  else
    [defaults removeObjectForKey:@"TerminalSettings"];
  {
    NSEnumerator *enumerator = [profileKeys objectEnumerator];
    NSString *key;
    while ((key = [enumerator nextObject]) != nil)
      {
        id value = [savedProfiles objectForKey:key];
        if (value)
          [defaults setObject:value forKey:key];
        else
          [defaults removeObjectForKey:key];
      }
  }
  [defaults synchronize];
  RELEASE (saved);
  NSLog (@"%lu checks, %lu failures; rendered evidence in %@",
         (unsigned long)checks, (unsigned long)failures, directory);
  RELEASE (pool);
  return failures ? 1 : 0;
}
