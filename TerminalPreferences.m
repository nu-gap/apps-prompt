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

#import "TerminalPreferences.h"
#include <math.h>
NSString *TerminalPreferencesDidChangeNotification
    = @"TerminalPreferencesDidChange";
@implementation TerminalPreferences

/* Keep the original settings key as the built-in Default profile. */
+ (NSDictionary *)profiles
{
  return [[NSUserDefaults standardUserDefaults]
             dictionaryForKey:@"TerminalProfiles"]
             ?: [NSDictionary dictionary];
}

+ (NSArray *)profileNames
{
  NSMutableArray *names = [NSMutableArray arrayWithObject:@"Default"];
  {
    NSEnumerator *enumerator = [[self profiles] keyEnumerator];
    id name;
    while ((name = [enumerator nextObject]) != nil)
      {
        if ([name isKindOfClass:[NSString class]] && ![name isEqual:@"Default"]
            && [[[self profiles] objectForKey:name]
                isKindOfClass:[NSDictionary class]])
          [names addObject:name];
      }
  }
  return [names
      sortedArrayUsingSelector:@selector (localizedCaseInsensitiveCompare:)];
}

+ (NSString *)selectedProfileName
{
  NSString *name = [[NSUserDefaults standardUserDefaults]
      stringForKey:@"TerminalSelectedProfile"];
  return [[self profileNames] containsObject:name] ? name : @"Default";
}

+ (void)selectProfile:(NSString *)name
{
  if (![[self profileNames] containsObject:name])
    return;
  [[NSUserDefaults standardUserDefaults] setObject:name
                                            forKey:@"TerminalSelectedProfile"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)defaultProfileName
{
  NSString *name = [[NSUserDefaults standardUserDefaults]
      stringForKey:@"TerminalDefaultProfile"];
  return [[self profileNames] containsObject:name] ? name : @"Default";
}

+ (void)setDefaultProfileName:(NSString *)name
{
  if (![[self profileNames] containsObject:name])
    return;
  [[NSUserDefaults standardUserDefaults] setObject:name
                                            forKey:@"TerminalDefaultProfile"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (id)initWithProfileName:(NSString *)name
{
  if ((self = [super init]))
    ASSIGNCOPY (_profileName, name);
  return self;
}

- (void)dealloc
{
  RELEASE (_profileName);
  [super dealloc];
}

- (NSDictionary *)terminalSettings
{
  if ([_profileName isEqual:@"Default"])
    return [[NSUserDefaults standardUserDefaults]
               dictionaryForKey:@"TerminalSettings"]
               ?: [NSDictionary dictionary];
  id settings = [[TerminalPreferences profiles] objectForKey:_profileName];
  return [settings isKindOfClass:[NSDictionary class]]
             ? settings
             : [NSDictionary dictionary];
}

+ (NSDictionary *)terminalSettings
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalSettings];
}

+ (void)saveTerminalSettings:(NSDictionary *)settings
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *name = [self selectedProfileName];
  if ([name isEqual:@"Default"])
    [defaults setObject:settings forKey:@"TerminalSettings"];
  else
    {
      NSMutableDictionary *profiles =
          [NSMutableDictionary dictionaryWithDictionary:[self profiles]];
      [profiles setObject:settings forKey:name];
      [defaults setObject:profiles forKey:@"TerminalProfiles"];
    }
  [defaults synchronize];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:TerminalPreferencesDidChangeNotification
                    object:name];
}

+ (BOOL)validNewProfileName:(NSString *)name
{
  if (![name isKindOfClass:[NSString class]] || [name length] == 0 ||
      [name length] > 80 ||
      [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]]
              .location
          != NSNotFound
      || ![name
          isEqual:[name stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]]])
    return NO;
  {
    NSEnumerator *enumerator = [[self profileNames] objectEnumerator];
    NSString *existing;
    while ((existing = [enumerator nextObject]) != nil)
      if ([existing caseInsensitiveCompare:name] == NSOrderedSame)
        return NO;
  }
  return YES;
}

+ (BOOL)duplicateSelectedProfileWithName:(NSString *)name
{
  if (![self validNewProfileName:name])
    return NO;
  NSMutableDictionary *profiles =
      [NSMutableDictionary dictionaryWithDictionary:[self profiles]];
  [profiles setObject:[self terminalSettings] forKey:name];
  [[NSUserDefaults standardUserDefaults] setObject:profiles
                                            forKey:@"TerminalProfiles"];
  [self selectProfile:name];
  return YES;
}

+ (BOOL)renameSelectedProfile:(NSString *)name
{
  NSString *old = AUTORELEASE ([[self selectedProfileName] copy]);
  if ([old isEqual:@"Default"] || ![self validNewProfileName:name])
    return NO;
  BOOL wasDefault = [[self defaultProfileName] isEqual:old];
  NSMutableDictionary *profiles =
      [NSMutableDictionary dictionaryWithDictionary:[self profiles]];
  [profiles setObject:[self terminalSettings] forKey:name];
  [profiles removeObjectForKey:old];
  [[NSUserDefaults standardUserDefaults] setObject:profiles
                                            forKey:@"TerminalProfiles"];
  [self selectProfile:name];
  if (wasDefault)
    [self setDefaultProfileName:name];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:TerminalPreferencesDidChangeNotification
                    object:old
                  userInfo:[NSDictionary
                               dictionaryWithObject:name
                                             forKey:@"replacementProfile"]];
  return YES;
}

+ (BOOL)deleteSelectedProfile
{
  NSString *old = AUTORELEASE ([[self selectedProfileName] copy]);
  if ([old isEqual:@"Default"])
    return NO;
  BOOL wasDefault = [[self defaultProfileName] isEqual:old];
  NSMutableDictionary *profiles =
      [NSMutableDictionary dictionaryWithDictionary:[self profiles]];
  [profiles removeObjectForKey:old];
  [[NSUserDefaults standardUserDefaults] setObject:profiles
                                            forKey:@"TerminalProfiles"];
  [self selectProfile:@"Default"];
  if (wasDefault)
    [self setDefaultProfileName:@"Default"];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:TerminalPreferencesDidChangeNotification
                    object:old
                  userInfo:[NSDictionary
                               dictionaryWithObject:@"Default"
                                             forKey:@"replacementProfile"]];
  return YES;
}

+ (void)setTerminalValue:(id)value forKey:(NSString *)key
{
  NSMutableDictionary *settings =
      [NSMutableDictionary dictionaryWithDictionary:[self terminalSettings]];
  [settings setObject:value forKey:key];
  [self saveTerminalSettings:settings];
}

+ (BOOL)isTerminalFont:(NSFont *)font
{
  if (!font)
    return NO;
  if ([font isFixedPitch]
      || ([[NSFontManager sharedFontManager] traitsOfFont:font]
          & NSFixedPitchFontMask))
    return YES;
  /* Some GNUstep font backends omit the fixed-pitch flag even for the
   system's default monospace face. Check its advances in that case. */
  NSDictionary *attributes =
      [NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName];
  CGFloat width = [@"M" sizeWithAttributes:attributes].width;
  return width > 0
         && fabs ([@"i" sizeWithAttributes:attributes].width - width) < 0.01
         && fabs ([@"W" sizeWithAttributes:attributes].width - width) < 0.01
         && fabs ([@" " sizeWithAttributes:attributes].width - width) < 0.01;
}

- (NSFont *)terminalFont
{
  NSDictionary *settings = [self terminalSettings];
  id name = [settings objectForKey:@"fontName"],
     size = [settings objectForKey:@"fontSize"];
  if ([name isKindOfClass:[NSString class]] &&
      [size isKindOfClass:[NSNumber class]] && isfinite ([size doubleValue]) &&
      [size doubleValue] >= 6 && [size doubleValue] <= 72)
    {
      NSFont *font = [NSFont fontWithName:name size:[size doubleValue]];
      if ([TerminalPreferences isTerminalFont:font])
        return font;
    }
  return [NSFont userFixedPitchFontOfSize:13];
}

+ (void)setTerminalFont:(NSFont *)font
{
  if (![TerminalPreferences isTerminalFont:font] || !isfinite ([font pointSize])
      || [font pointSize] < 6 || [font pointSize] > 72)
    return;
  NSMutableDictionary *settings =
      [NSMutableDictionary dictionaryWithDictionary:[self terminalSettings]];
  [settings setObject:[font fontName] forKey:@"fontName"];
  [settings setObject:[NSNumber numberWithDouble:[font pointSize]]
               forKey:@"fontSize"];
  [self saveTerminalSettings:settings];
}

- (NSColor *)terminalColorForKey:(NSString *)key
                    defaultColor:(NSColor *)fallback
{
  id rgb = [[self terminalSettings] objectForKey:key];
  if ([rgb isKindOfClass:[NSArray class]] && [rgb count] == 3)
    {
      NSUInteger i;
      for (i = 0; i < 3; i++)
        {
          id component = [rgb objectAtIndex:i];
          if (![component isKindOfClass:[NSNumber class]]
              || !isfinite ([component doubleValue]) ||
              [component doubleValue] < 0 || [component doubleValue] > 1)
            break;
        }
      if (i == 3)
        return
            [NSColor colorWithCalibratedRed:[[rgb objectAtIndex:0] doubleValue]
                                      green:[[rgb objectAtIndex:1] doubleValue]
                                       blue:[[rgb objectAtIndex:2] doubleValue]
                                      alpha:1];
    }
  return fallback;
}

- (NSColor *)terminalForegroundColor
{
  return
      [self terminalColorForKey:@"foreground"
                   defaultColor:[NSColor colorWithCalibratedWhite:230.0 / 255.0
                                                            alpha:1]];
}

- (NSColor *)terminalBackgroundColor
{
  return
      [self terminalColorForKey:@"background"
                   defaultColor:[NSColor colorWithCalibratedWhite:24.0 / 255.0
                                                            alpha:1]];
}

+ (void)setTerminalForegroundColor:(NSColor *)foreground
                   backgroundColor:(NSColor *)background
{
  NSMutableDictionary *settings =
      [NSMutableDictionary dictionaryWithDictionary:[self terminalSettings]];
  NSArray *colors = [NSArray arrayWithObjects:foreground, background, nil];
  NSArray *keys = [NSArray arrayWithObjects:@"foreground", @"background", nil];
  if ([colors count] != 2)
    return;
  NSUInteger i;
  for (i = 0; i < 2; i++)
    {
      NSColor *color = [[colors objectAtIndex:i]
          colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
      if (!color)
        return;
      [settings
          setObject:[NSArray
                        arrayWithObjects:
                            [NSNumber numberWithDouble:[color redComponent]],
                            [NSNumber numberWithDouble:[color greenComponent]],
                            [NSNumber numberWithDouble:[color blueComponent]],
                            nil]
             forKey:[keys objectAtIndex:i]];
    }
  [self saveTerminalSettings:settings];
}

- (NSColor *)terminalCursorColor
{
  return [self terminalColorForKey:@"cursorColor"
                      defaultColor:[NSColor redColor]];
}

+ (void)setTerminalCursorColor:(NSColor *)color
{
  color = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  if (!color)
    return;
  [self
      setTerminalValue:
          [NSArray
              arrayWithObjects:[NSNumber numberWithDouble:[color redComponent]],
                               [NSNumber
                                   numberWithDouble:[color greenComponent]],
                               [NSNumber
                                   numberWithDouble:[color blueComponent]],
                               nil]
                forKey:@"cursorColor"];
}

- (NSInteger)terminalCursorShape
{
  id value = [[self terminalSettings] objectForKey:@"cursorShape"];
  return [value isKindOfClass:[NSNumber class]] && [value integerValue] >= 0 &&
                 [value integerValue] <= 4
             ? [value integerValue]
             : 0;
}

+ (void)setTerminalCursorShape:(NSInteger)shape
{
  if (shape >= 0 && shape <= 4)
    [self setTerminalValue:[NSNumber numberWithInteger:shape]
                    forKey:@"cursorShape"];
}

- (NSUInteger)terminalScrollbackLines
{
  id lines = [[self terminalSettings] objectForKey:@"scrollbackLines"];
  return [lines isKindOfClass:[NSNumber class]] && [lines integerValue] >= 0 &&
                 [lines integerValue] <= 50000
             ? [lines unsignedIntegerValue]
             : 5000;
}

+ (void)setTerminalScrollbackLines:(NSUInteger)lines
{
  [self setTerminalValue:[NSNumber numberWithUnsignedInteger:MIN (50000, lines)]
                  forKey:@"scrollbackLines"];
}

- (NSUInteger)terminalDimensionForKey:(NSString *)key
                             fallback:(NSUInteger)fallback
{
  id value = [[self terminalSettings] objectForKey:key];
  double number =
      [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
  return isfinite (number) && number >= 2 && number <= 1000
                 && floor (number) == number
             ? (NSUInteger)number
             : fallback;
}

- (NSUInteger)terminalColumns
{
  return [self terminalDimensionForKey:@"columns" fallback:80];
}

- (NSUInteger)terminalRows
{
  return [self terminalDimensionForKey:@"rows" fallback:25];
}

+ (void)setTerminalColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
  if (columns < 2 || columns > 1000 || rows < 2 || rows > 1000)
    return;
  NSMutableDictionary *settings =
      [NSMutableDictionary dictionaryWithDictionary:[self terminalSettings]];
  [settings setObject:[NSNumber numberWithUnsignedInteger:columns]
               forKey:@"columns"];
  [settings setObject:[NSNumber numberWithUnsignedInteger:rows] forKey:@"rows"];
  [self saveTerminalSettings:settings];
}

- (BOOL)terminalBooleanForKey:(NSString *)key
{
  id value = [[self terminalSettings] objectForKey:key];
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (BOOL)terminalAudibleBell
{
  return [self terminalBooleanForKey:@"audibleBell"];
}

- (BOOL)terminalCursorBlink
{
  return [self terminalBooleanForKey:@"cursorBlink"];
}

+ (void)setTerminalAudibleBell:(BOOL)enabled
{
  [self setTerminalValue:[NSNumber numberWithBool:enabled]
                  forKey:@"audibleBell"];
}

+ (void)setTerminalCursorBlink:(BOOL)enabled
{
  [self setTerminalValue:[NSNumber numberWithBool:enabled]
                  forKey:@"cursorBlink"];
}

- (BOOL)terminalCloseOnExit
{
  id value = [[self terminalSettings] objectForKey:@"closeOnExit"];
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

+ (BOOL)terminalCloseOnExit
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalCloseOnExit];
}

+ (void)setTerminalCloseOnExit:(BOOL)enabled
{
  [self setTerminalValue:[NSNumber numberWithBool:enabled]
                  forKey:@"closeOnExit"];
}

- (BOOL)terminalConfirmClose
{
  return [self terminalBooleanForKey:@"confirmClose"];
}

+ (BOOL)terminalConfirmClose
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalConfirmClose];
}

+ (void)setTerminalConfirmClose:(BOOL)enabled
{
  [self setTerminalValue:[NSNumber numberWithBool:enabled] forKey:@"confirmClose"];
}

- (BOOL)terminalShowProcess
{
  return [self terminalBooleanForKey:@"showProcess"];
}

+ (BOOL)terminalShowProcess
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalShowProcess];
}

+ (void)setTerminalShowProcess:(BOOL)enabled
{
  [self setTerminalValue:[NSNumber numberWithBool:enabled] forKey:@"showProcess"];
}

+ (void)resetTerminalPreferences
{
  [self saveTerminalSettings:[NSDictionary dictionary]];
}

+ (NSFont *)terminalFont
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalFont];
}

+ (NSColor *)terminalForegroundColor
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalForegroundColor];
}

+ (NSColor *)terminalBackgroundColor
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalBackgroundColor];
}

+ (NSColor *)terminalCursorColor
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalCursorColor];
}

+ (NSInteger)terminalCursorShape
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalCursorShape];
}

+ (NSUInteger)terminalScrollbackLines
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalScrollbackLines];
}

+ (NSUInteger)terminalColumns
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalColumns];
}

+ (NSUInteger)terminalRows
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalRows];
}

+ (BOOL)terminalAudibleBell
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalAudibleBell];
}

+ (BOOL)terminalCursorBlink
{
  return [AUTORELEASE ([[self alloc]
      initWithProfileName:[self selectedProfileName]]) terminalCursorBlink];
}

@end
