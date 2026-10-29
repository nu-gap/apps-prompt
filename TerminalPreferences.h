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

#import <AppKit/AppKit.h>
extern NSString *TerminalPreferencesDidChangeNotification;
/** Class accessors edit the selected profile; instances read a particular
 * profile. */
@interface TerminalPreferences : NSObject
{
  NSString *_profileName;
}
+ (NSArray *)profileNames;
+ (NSString *)selectedProfileName;
+ (void)selectProfile:(NSString *)name;
+ (NSString *)defaultProfileName;
+ (void)setDefaultProfileName:(NSString *)name;
+ (BOOL)duplicateSelectedProfileWithName:(NSString *)name;
+ (BOOL)renameSelectedProfile:(NSString *)name;
+ (BOOL)deleteSelectedProfile;
- (id)initWithProfileName:(NSString *)name;
+ (BOOL)isTerminalFont:(NSFont *)font;
+ (NSFont *)terminalFont;
- (NSFont *)terminalFont;

+ (void)setTerminalFont:(NSFont *)font;
+ (NSColor *)terminalForegroundColor;
- (NSColor *)terminalForegroundColor;
+ (NSColor *)terminalBackgroundColor;
- (NSColor *)terminalBackgroundColor;
+ (void)setTerminalForegroundColor:(NSColor *)foreground
                   backgroundColor:(NSColor *)background;
+ (NSColor *)terminalCursorColor;
- (NSColor *)terminalCursorColor;
+ (void)setTerminalCursorColor:(NSColor *)color;
/** Cursor shape: 0 program controlled, 1 block, 2 outline, 3 line, 4 underline.
 */
+ (NSInteger)terminalCursorShape;
- (NSInteger)terminalCursorShape;
+ (void)setTerminalCursorShape:(NSInteger)shape;
+ (NSUInteger)terminalScrollbackLines;
- (NSUInteger)terminalScrollbackLines;
+ (void)setTerminalScrollbackLines:(NSUInteger)lines;
+ (NSUInteger)terminalColumns;
- (NSUInteger)terminalColumns;
+ (NSUInteger)terminalRows;
- (NSUInteger)terminalRows;
+ (void)setTerminalColumns:(NSUInteger)columns rows:(NSUInteger)rows;
+ (BOOL)terminalAudibleBell;
- (BOOL)terminalAudibleBell;
+ (void)setTerminalAudibleBell:(BOOL)enabled;
+ (BOOL)terminalCursorBlink;
- (BOOL)terminalCursorBlink;
+ (void)setTerminalCursorBlink:(BOOL)enabled;
+ (BOOL)terminalCloseOnExit;
- (BOOL)terminalCloseOnExit;
+ (void)setTerminalCloseOnExit:(BOOL)enabled;
+ (BOOL)terminalConfirmClose;
- (BOOL)terminalConfirmClose;
+ (void)setTerminalConfirmClose:(BOOL)enabled;
+ (BOOL)terminalShowProcess;
- (BOOL)terminalShowProcess;
+ (void)setTerminalShowProcess:(BOOL)enabled;
+ (void)resetTerminalPreferences;
@end
