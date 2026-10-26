/*
 * This file is part of Terminal.app.
 * Copyright (C) 2026 Terminal contributors.
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License, version 3 or later.
 * This program is distributed WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See <https://www.gnu.org/licenses/> for a copy of the license.
 */

/*
copyright 2002 Alexander Malmberg <alexander@malmberg.org>

This file is a part of Terminal.app. Terminal.app is free software; you
can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation; version 2
of the License. See COPYING or main.m for more information.
*/

#ifndef Terminal_h
#define Terminal_h

#import <Foundation/Foundation.h>
#include <stdint.h>

@class NSEvent;

/* Application-owned terminal data. No external emulator ABI is exposed. */
typedef enum
{
  TerminalColorRGB,
  TerminalColorIndexed,
  TerminalColorDefaultForeground,
  TerminalColorDefaultBackground
} TerminalColorKind;

typedef struct
{
  TerminalColorKind kind;
  unsigned char index;
  struct
  {
    unsigned char red, green, blue;
  } rgb;
} TerminalColor;

typedef struct
{
  uint32_t chars[6];
  unsigned char width;
  unsigned short attributes;
  TerminalColor fg, bg;
} TerminalGlyph;

enum
{
  TerminalBold = 1,
  TerminalUnderline = 2,
  TerminalReverse = 4,
  TerminalBlink = 8,
  TerminalConceal = 16,
  TerminalItalic = 32,
  TerminalStrike = 64,
  TerminalProtected = 128,
  TerminalDim = 256,
  TerminalDoubleUnderline = 512,
  /* Internal row metadata, retained in scrollback. */
  TerminalSoftWrap = 1024,
  TerminalWrapPadding = 2048
};

typedef struct
{
  /* Preserve full cells when history is restored after a resize. */
  TerminalGlyph originalCell;
  /* Resolved display colors; original palette indices stay in history. */
  TerminalColor foreground, background;
  unichar ch;
  unsigned char color;
  unsigned char attr;
  /*
  bits
  0,1   intensity, 0-2
  2     underline
  3     reverse
  4     blink
  5     unused
  6     used as a selected flag internally
  7     used as a dirty flag internally
  */
} screen_char_t;

/* Used as a marker. */
#define MULTI_CELL_GLYPH 0xfffe

typedef struct
{
  int row, col;
} TerminalPosition;
typedef struct
{
  int start_row, end_row, start_col, end_col;
} TerminalRect;
enum
{
  TerminalCursorBlock = 1,
  TerminalCursorUnderline,
  TerminalCursorBar
};

@protocol TerminalScreen

- (void)ts_sendCString:(const char *)bytes length:(int)length;
- (void)ts_goto:(int)x :(int)y;
- (void)ts_putChar:(screen_char_t)cell count:(int)count at:(int)x :(int)y;
- (void)ts_setTitle:(NSString *)title type:(int)type;
- (void)ts_setCursorVisible:(BOOL)visible;
- (void)ts_clearScrollback;
- (void)ts_appendScrollback:(const screen_char_t *)cells count:(int)count;
- (BOOL)ts_popScrollback:(screen_char_t *)cells count:(int)count;
- (void)ts_setAlternate:(BOOL)enabled;
- (void)ts_setMouse:(BOOL)enabled;
- (void)ts_setCursorShape:(int)shape blink:(BOOL)blink;
- (void)ringBell;

@end

@protocol TerminalParser

- initWithTerminalScreen:(id<TerminalScreen>)ats width:(int)w height:(int)h;
- (void)processByte:(unsigned char)c;
- (void)processBytes:(const char *)bytes length:(NSUInteger)length;
- (void)setTerminalScreenWidth:(int)w height:(int)h;
- (void)handleKeyEvent:(NSEvent *)e;
- (void)sendString:(NSString *)str;

@end

#endif
