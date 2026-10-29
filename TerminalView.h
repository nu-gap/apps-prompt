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

#ifndef _TERMINALVIEW_H_
#define _TERMINALVIEW_H_

#import <AppKit/AppKit.h>
#import "Terminal/TerminalParser_VT100.h"

/** An independent interactive terminal. Screen and nonblocking PTY I/O use the
 * main run loop. */
@interface TerminalView : NSView <TerminalScreen>
{
  TerminalParser_VT100 *_terminal;
  TerminalPosition _cursorPosition;
  NSMutableArray *_history;
  NSMutableData *_pendingInput;
  NSString *_directory;
  NSString *_shellPath;
  NSString *_profileName;
  NSFont *_font;
  NSFont *_boldFont;
  NSColor *_foregroundColor, *_backgroundColor, *_cursorColor;
  NSInteger _preferredCursorShape;
  NSUInteger _scrollbackLimit;
  BOOL _audibleBell, _allowCursorBlink, _closeOnExit;
  BOOL _confirmClose, _showProcess;
  NSTimeInterval _lastSessionUpdate;
  NSTimer *_timer;
  NSTimer *_resizeTimer;
  void *_resizeDisplay;
  BOOL _showResizeIndicator;
  int _master;
  int _child;
  int _session;
  int _rows, _columns;
  CGFloat _cellWidth, _cellHeight;
  NSScroller *_historyScroller;
  CGFloat _wheelRemainder;
  NSInteger _scrollOffset;
  NSInteger _selectionStart, _selectionEnd;
  BOOL _cursorVisible, _alternateScreen, _mouseReporting;
  BOOL _ended;
  BOOL _blinkOn, _cursorBlink;
  int _cursorShape;
  NSTimeInterval _lastBlink;
}

/** Starts an interactive shell in directory. Repeated calls preserve a running
 * shell. */

- (BOOL)startInDirectory:(NSString *)directory error:(NSError **)error;
/** Hangs up the terminal and reaps its shell, without blocking the UI. */

- (void)stop;
/** Used during application termination, after stopping all sessions. */
+ (void)waitForChildCleanup;

/** Content size for a character grid using the current font. */
- (NSSize)contentSizeForColumns:(NSUInteger)columns rows:(NSUInteger)rows;

- (NSString *)profileName;
- (void)setProfileName:(NSString *)name;

- (BOOL)isRunning;
- (BOOL)hasActiveJobs;
- (BOOL)requiresCloseConfirmation;
- (NSString *)runningProcessName;

- (void)restart:(id)sender;

- (void)copy:(id)sender;

- (void)paste:(id)sender;

- (void)selectAll:(id)sender;
/** Feed terminal bytes, preserving parser state across partial sequences. */

- (void)consumeData:(NSData *)data;
/** Queue input for the PTY without blocking on a slow reader. */

- (void)sendData:(NSData *)data;

- (NSString *)screenText;

@end
#endif
