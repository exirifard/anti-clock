#!/usr/bin/env python3
"""watchface.py - pure drawing + math for the anticlockwise watch.

A faithful pycairo port of js/clockmath.js, js/dial.js and js/hands.js.
Imports only math, datetime and cairo (no GTK), so it can render to an
off-screen cairo.ImageSurface with no display at all.

Public API
----------
THEME                               colour table (hex strings) + font family
hand_angles(t)                      -> {'hour': th, 'minute': th, 'second': th}
point_at(cx, cy, r, theta, mirror)  -> (x, y)
numeral_theta(n)                    -> theta of numeral n (12 -> 0, top)
drift_offset(t_seconds, amplitude)  -> (dx, dy) slow Lissajous, |.| <= amplitude
parse_time("HH:MM[:SS[.mmm]]")      -> (h, m, s, ms) or None
draw_watch(cr, width, height, when, mirror=True, drift=(0, 0), show_seconds=True)

ANGLE CONTRACT
  theta is in radians, measured from 12 o'clock, increasing CLOCKWISE on a
  NORMAL clock. A normal clock point is x = cx + r*sin(theta),
  y = cy - r*cos(theta). The watch runs anticlockwise by mirroring across the
  vertical axis (mirror=True -> x = cx - r*sin(theta)). Hands are ALWAYS drawn
  mirrored; the dial honours the `mirror` flag (True => numerals read 12 top,
  3 LEFT, 6 bottom, 9 RIGHT so the mirrored hands still show the right time).
"""

import datetime
import math

import cairo

TWO_PI = 2.0 * math.pi
PI = math.pi

THEME = {
    'bg': '#000000',
    'face': '#111317',
    'bezel': '#2a2e36',
    'bezelHighlight': '#4a505c',
    'tick': '#9aa3b2',
    'tickMajor': '#e6e9ef',
    'numeral': '#e6e9ef',
    'hour': '#e6e9ef',
    'minute': '#e6e9ef',
    'second': '#e0452e',
    'cap': '#e6e9ef',
    # cairo "toy" font family; fontconfig substitutes the default sans-serif
    # if this family is not installed.
    'font': 'Noto Sans',
}

# Hand geometry as fractions of r (identical to hands.js).
HOUR_HAND = {'len': 0.52, 'width': 0.06, 'tail': 0.12}
MINUTE_HAND = {'len': 0.76, 'width': 0.045, 'tail': 0.14}
SECOND_HAND = {'len': 0.86, 'width': 0.015, 'tail': 0.2}


# --------------------------------------------------------------------------
# Colour helpers
# --------------------------------------------------------------------------

def hex_to_rgb(colour):
    """'#rrggbb' or '#rgb' -> (r, g, b) floats in 0..1."""
    s = colour.strip().lstrip('#')
    if len(s) == 3:
        s = ''.join(ch * 2 for ch in s)
    if len(s) != 6:
        raise ValueError('bad hex colour: %r' % (colour,))
    return tuple(int(s[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def set_colour(cr, colour, alpha=None):
    r, g, b = hex_to_rgb(colour)
    if alpha is None:
        cr.set_source_rgb(r, g, b)
    else:
        cr.set_source_rgba(r, g, b, alpha)


# --------------------------------------------------------------------------
# Pure math (port of clockmath.js)
# --------------------------------------------------------------------------

def point_at(cx, cy, r, theta, mirror=True):
    """Point on a circle of radius r centred at (cx, cy) at NORMAL-clock
    angle theta. mirror=True flips across the vertical axis so increasing
    theta moves anticlockwise on screen."""
    s = r * math.sin(theta)
    x = cx - s if mirror else cx + s
    y = cy - r * math.cos(theta)
    return (x, y)


def hand_angles(t):
    """NORMAL-clock hand angles (radians, clockwise-positive) for a
    datetime.datetime or datetime.time `t` (local time)."""
    h = t.hour
    m = t.minute
    s = t.second
    us = getattr(t, 'microsecond', 0)
    sec = s + us / 1e6
    return {
        'second': TWO_PI * sec / 60.0,
        'minute': TWO_PI * (m + sec / 60.0) / 60.0,
        'hour': TWO_PI * ((h % 12) + m / 60.0 + s / 3600.0) / 12.0,
    }


def numeral_theta(n):
    """NORMAL-clock angle of numeral n (1..12); 12 -> 0 (top)."""
    return TWO_PI * (n % 12) / 12.0


def drift_offset(t_seconds, amplitude):
    """Slow Lissajous offset for burn-in protection (periods ~97 s and
    ~131 s). Magnitude never exceeds `amplitude` because each axis is
    scaled by amplitude/sqrt(2). Returns (0.0, 0.0) when amplitude is 0."""
    if not amplitude:
        return (0.0, 0.0)
    a = amplitude / math.sqrt(2.0)
    dx = a * math.sin(TWO_PI * t_seconds / 97.0)
    dy = a * math.sin(TWO_PI * t_seconds / 131.0 + PI / 3.0)
    return (dx, dy)


def _digits(s, lo, hi):
    """True if s is 'lo'..'hi' ASCII digits long."""
    return lo <= len(s) <= hi and all(ch in '0123456789' for ch in s)


def parse_time(text):
    """Parse "HH:MM", "HH:MM:SS" or "HH:MM:SS.mmm" -> (h, m, s, ms).
    Returns None on bad input or out-of-range fields (same grammar as
    clockmath.js: 1-2 digit hour, 2 digit minute/second, 1-3 digit ms)."""
    if not isinstance(text, str):
        return None
    parts = text.strip().split(':')
    if len(parts) not in (2, 3):
        return None
    hh, mm = parts[0], parts[1]
    if not _digits(hh, 1, 2) or not _digits(mm, 2, 2):
        return None
    ss, frac = '0', '0'
    if len(parts) == 3:
        ss, _dot, frac = parts[2].partition('.')
        if not _digits(ss, 2, 2):
            return None
        if _dot and not _digits(frac, 1, 3):
            return None
        if not _dot:
            frac = '0'
    h, mi, s = int(hh), int(mm), int(ss)
    ms = int((frac + '00')[:3]) if len(parts) == 3 and _dot else 0
    if h > 23 or mi > 59 or s > 59:
        return None
    return (h, mi, s, ms)


def with_time(dt, parsed):
    """Return `dt` (a datetime) with its clock fields replaced by the
    (h, m, s, ms) tuple from parse_time(). Convenience for --time."""
    h, m, s, ms = parsed
    return dt.replace(hour=h, minute=m, second=s, microsecond=ms * 1000)


# --------------------------------------------------------------------------
# Drawing (port of dial.js and hands.js)
# --------------------------------------------------------------------------

def _circle(cr, cx, cy, radius):
    cr.new_path()
    cr.arc(cx, cy, radius, 0.0, TWO_PI)


def draw_dial(cr, cx, cy, r, mirror=True, theme=THEME):
    """Static watch face: face disc, bezel, highlight ring, ticks, numerals."""
    cr.save()
    # Grey-scale text antialiasing: otherwise cairo-ft inherits the host
    # fontconfig rgba setting (subpixel/LCD) even on an off-screen
    # ImageSurface, giving coloured fringes on the numerals and making the
    # render depend on the machine instead of purely on its inputs.
    fo = cairo.FontOptions()
    fo.set_antialias(cairo.ANTIALIAS_GRAY)
    cr.set_font_options(fo)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)

    # Face
    _circle(cr, cx, cy, r)
    set_colour(cr, theme['face'])
    cr.fill()

    # Outer bezel ring, centred on the rim
    w = 0.045 * r
    _circle(cr, cx, cy, r - w / 2.0)
    cr.set_line_width(w)
    set_colour(cr, theme['bezel'])
    cr.stroke()

    # Thin inner highlight ring just inside the bezel
    _circle(cr, cx, cy, r - w - 0.006 * r)
    cr.set_line_width(max(1.0, 0.008 * r))
    set_colour(cr, theme['bezelHighlight'])
    cr.stroke()

    # Ticks: 60 minute ticks (short, thin) and 12 hour ticks (longer, thicker).
    # Major ticks end at tickOuter - 0.06r = 0.865r, clear of the numerals.
    tick_outer = r - w - 0.03 * r
    for n in range(60):
        theta = TWO_PI * n / 60.0
        major = (n % 5 == 0)
        length = 0.06 * r if major else 0.045 * r
        px, py = point_at(cx, cy, tick_outer, theta, mirror)
        qx, qy = point_at(cx, cy, tick_outer - length, theta, mirror)
        cr.new_path()
        cr.move_to(px, py)
        cr.line_to(qx, qy)
        cr.set_line_width(max(1.0, (0.02 if major else 0.008) * r))
        set_colour(cr, theme['tickMajor'] if major else theme['tick'])
        cr.stroke()

    # Numerals 1..12 at 0.70 r, glyphs upright (never flipped), centred.
    px_size = max(1, int(round(0.16 * r)))
    cr.select_font_face(theme['font'], cairo.FONT_SLANT_NORMAL,
                        cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(px_size)
    set_colour(cr, theme['numeral'])
    for n in range(1, 13):
        label = str(n)
        x, y = point_at(cx, cy, 0.70 * r, numeral_theta(n), mirror)
        x_bearing, y_bearing, tw, th, _xa, _ya = cr.text_extents(label)
        cr.move_to(x - (x_bearing + tw / 2.0), y - (y_bearing + th / 2.0))
        cr.show_text(label)
    cr.new_path()

    cr.restore()


def _stroke_hand(cr, cx, cy, r, theta, spec, colour, shadow_dy):
    """One hand as a single round-capped line from tail (theta + PI) to tip,
    always mirrored. Draws a translucent offset copy first as a cheap
    approximation of the canvas shadow in hands.js."""
    tip = point_at(cx, cy, spec['len'] * r, theta, True)
    tail = point_at(cx, cy, spec['tail'] * r, theta + PI, True)
    width = max(1.0, spec['width'] * r)

    if shadow_dy:
        cr.new_path()
        cr.move_to(tail[0], tail[1] + shadow_dy)
        cr.line_to(tip[0], tip[1] + shadow_dy)
        cr.set_line_width(width + 0.01 * r)
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.35)
        cr.stroke()

    cr.new_path()
    cr.move_to(tail[0], tail[1])
    cr.line_to(tip[0], tip[1])
    cr.set_line_width(width)
    set_colour(cr, colour)
    cr.stroke()
    return tip, tail


def draw_hands(cr, cx, cy, r, angles, show_seconds=True, theme=THEME):
    """Hour, minute and (optional) second hand plus the centre cap.
    `angles` = {'hour', 'minute', 'second'} NORMAL-clock thetas from
    hand_angles(); every point is drawn mirrored (anticlockwise sweep)."""
    cr.save()
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)

    shadow_dy = 0.006 * r

    _stroke_hand(cr, cx, cy, r, angles['hour'], HOUR_HAND, theme['hour'], shadow_dy)
    _stroke_hand(cr, cx, cy, r, angles['minute'], MINUTE_HAND, theme['minute'], shadow_dy)

    second = angles.get('second') if show_seconds else None
    if second is not None:
        _stroke_hand(cr, cx, cy, r, second, SECOND_HAND, theme['second'], shadow_dy)
        # Counterweight disc sitting on the tail, slightly inside the tail end.
        cw_radius = max(1.5, 0.03 * r)
        cwx, cwy = point_at(cx, cy, SECOND_HAND['tail'] * r - cw_radius, second + PI, True)
        _circle(cr, cwx, cwy, cw_radius)
        set_colour(cr, theme['second'])
        cr.fill()

    # Centre cap (no shadow) with a small red dot.
    cap_radius = 0.045 * r
    _circle(cr, cx, cy, cap_radius)
    set_colour(cr, theme['cap'])
    cr.fill()
    _circle(cr, cx, cy, cap_radius * 0.45)
    set_colour(cr, theme['second'])
    cr.fill()

    cr.restore()


def draw_watch(cr, width, height, when, mirror=True, drift=(0.0, 0.0),
               show_seconds=True, theme=THEME):
    """Render one complete frame into cairo context `cr`.

    Fills the whole width x height with THEME bg, then draws the dial and
    hands with r = 0.42*min(width, height) centred at
    (width/2 + drift[0], height/2 + drift[1]). `when` is a datetime.datetime
    (or datetime.time) in local time. Pure function of its inputs."""
    cr.save()
    try:
        set_colour(cr, theme['bg'])
        cr.rectangle(0, 0, width, height)
        cr.fill()

        min_dim = min(width, height)
        r = 0.42 * min_dim
        cx = width / 2.0 + float(drift[0])
        cy = height / 2.0 + float(drift[1])

        angles = hand_angles(when)
        draw_dial(cr, cx, cy, r, mirror, theme)
        draw_hands(cr, cx, cy, r, angles, show_seconds, theme)
    finally:
        cr.restore()


__all__ = [
    'THEME', 'TWO_PI', 'HOUR_HAND', 'MINUTE_HAND', 'SECOND_HAND',
    'hex_to_rgb', 'set_colour', 'point_at', 'hand_angles', 'numeral_theta',
    'drift_offset', 'parse_time', 'with_time', 'draw_dial', 'draw_hands',
    'draw_watch',
]
