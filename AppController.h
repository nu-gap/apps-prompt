/* Standalone GNUstep Terminal. GPL-2.0-or-later; see COPYING. */
#import <AppKit/AppKit.h>
@class TerminalView;
@interface AppController : NSObject
{
  NSMutableArray *_windows;
  NSPanel *_preferences;
  NSWindow *_help;
  NSWindow *_lastTerminalWindow; /* owned by _windows */
  NSButton *_fontButton, *_bell, *_blink, *_closeOnExit, *_confirmClose, *_showProcess;
  NSColorWell *_foreground, *_background, *_cursor;
  NSPopUpButton *_shape, *_profiles;
  NSTextField *_profileName, *_profileStatus;
  NSButton *_renameProfile, *_deleteProfile, *_defaultProfile;
  NSTextField *_history, *_columns, *_rows;
}
- (BOOL)windowShouldClose:(id)window;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;
- (void)buildMenus;
- (void)newTerminal:(id)sender;
- (void)toggleTerminal:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (void)newTerminalInDirectory:(id)sender;
- (TerminalView *)openDirectory:(NSString *)directory;
- (void)selectProfile:(id)sender;
- (void)saveProfileCopy:(id)sender;
- (void)renameProfile:(id)sender;
- (void)deleteProfile:(id)sender;
- (void)makeDefaultProfile:(id)sender;
- (void)newTerminalWithProfile:(id)sender;
- (void)applyProfile:(id)sender;
- (void)showPreferences:(id)sender;
- (void)chooseFont:(id)sender;
- (void)changeFont:(id)sender;
- (void)changeColors:(id)sender;
- (void)changeSettings:(id)sender;
- (void)changeDimensions:(id)sender;
- (void)restoreDefaults:(id)sender;
- (void)showHelp:(id)sender;
@end
