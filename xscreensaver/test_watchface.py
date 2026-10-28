#!/usr/bin/env python3
"""Unit tests for watchface.py.  Run: python3 test_watchface.py  (exit 0 = pass)"""

import datetime
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cairo  # noqa: E402
import watchface as wf  # noqa: E402


def _pixel(surface, x, y):
    """Return (r, g, b) 0..255 of an ARGB32 ImageSurface pixel (native endian)."""
    surface.flush()
    data = surface.get_data()
    stride = surface.get_stride()
    off = int(y) * stride + int(x) * 4
    b0, b1, b2, b3 = data[off], data[off + 1], data[off + 2], data[off + 3]
    if sys.byteorder == 'little':
        b, g, r, a = b0, b1, b2, b3
    else:
        a, r, g, b = b0, b1, b2, b3
    return (r, g, b)


class PointAtTests(unittest.TestCase):
    def test_mirror_flips_x_only(self):
        theta = math.pi / 2  # 3 o'clock on a normal clock
        xm, ym = wf.point_at(100, 100, 50, theta, mirror=True)
        xn, yn = wf.point_at(100, 100, 50, theta, mirror=False)
        self.assertAlmostEqual(xm, 50.0)    # mirrored -> LEFT
        self.assertAlmostEqual(xn, 150.0)   # normal   -> RIGHT
        self.assertAlmostEqual(ym, 100.0)
        self.assertAlmostEqual(yn, 100.0)

    def test_default_is_mirror(self):
        self.assertEqual(wf.point_at(0, 0, 1, math.pi / 2),
                         wf.point_at(0, 0, 1, math.pi / 2, True))

    def test_twelve_is_top_regardless_of_mirror(self):
        for mirror in (True, False):
            x, y = wf.point_at(10, 20, 5, 0.0, mirror)
            self.assertAlmostEqual(x, 10.0)
            self.assertAlmostEqual(y, 15.0)


class HandAnglesTests(unittest.TestCase):
    def test_0300(self):
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 3, 0, 0))
        self.assertAlmostEqual(a['hour'], math.pi / 2)
        self.assertAlmostEqual(a['minute'], 0.0)
        self.assertAlmostEqual(a['second'], 0.0)

    def test_1200(self):
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 12, 0, 0))
        self.assertAlmostEqual(a['hour'], 0.0)
        self.assertAlmostEqual(a['minute'], 0.0)
        self.assertAlmostEqual(a['second'], 0.0)

    def test_1530(self):
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 15, 30, 0))
        self.assertAlmostEqual(a['hour'], 2 * math.pi * 3.5 / 12)
        self.assertAlmostEqual(a['minute'], math.pi)
        self.assertAlmostEqual(a['second'], 0.0)

    def test_microseconds_smooth_second_hand(self):
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 0, 0, 15, 500000))
        self.assertAlmostEqual(a['second'], 2 * math.pi * 15.5 / 60)
        self.assertAlmostEqual(a['minute'], 2 * math.pi * (15.5 / 60) / 60)

    def test_accepts_time_object(self):
        a = wf.hand_angles(datetime.time(6, 0, 0))
        self.assertAlmostEqual(a['hour'], math.pi)


class AnticlockwiseTests(unittest.TestCase):
    def test_hour_hand_points_left_at_0300(self):
        cx, cy, r = 200.0, 150.0, 100.0
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 3, 0, 0))
        x, _y = wf.point_at(cx, cy, 0.52 * r, a['hour'], True)
        self.assertLess(x, cx)

    def test_hour_hand_points_right_at_0900(self):
        cx, cy, r = 200.0, 150.0, 100.0
        a = wf.hand_angles(datetime.datetime(2026, 1, 1, 9, 0, 0))
        x, _y = wf.point_at(cx, cy, 0.52 * r, a['hour'], True)
        self.assertGreater(x, cx)


class NumeralThetaTests(unittest.TestCase):
    def test_values(self):
        self.assertAlmostEqual(wf.numeral_theta(12), 0.0)
        self.assertAlmostEqual(wf.numeral_theta(3), math.pi / 2)
        self.assertAlmostEqual(wf.numeral_theta(6), math.pi)
        self.assertAlmostEqual(wf.numeral_theta(9), 3 * math.pi / 2)

    def test_mirrored_dial_puts_3_on_the_left(self):
        x, _y = wf.point_at(100, 100, 50, wf.numeral_theta(3), True)
        self.assertLess(x, 100)
        x, _y = wf.point_at(100, 100, 50, wf.numeral_theta(9), True)
        self.assertGreater(x, 100)


class DriftOffsetTests(unittest.TestCase):
    def test_zero_amplitude(self):
        self.assertEqual(wf.drift_offset(12345.678, 0), (0.0, 0.0))
        self.assertEqual(wf.drift_offset(0, 0.0), (0.0, 0.0))

    def test_bounded(self):
        amp = 37.0
        t = 0.0
        while t < 97.0 * 131.0 + 1:
            dx, dy = wf.drift_offset(t, amp)
            self.assertLessEqual(math.hypot(dx, dy), amp + 1e-9, msg='t=%r' % t)
            t += 0.37

    def test_actually_moves(self):
        a = wf.drift_offset(0.0, 10.0)
        b = wf.drift_offset(20.0, 10.0)
        self.assertNotEqual(a, b)


class ParseTimeTests(unittest.TestCase):
    def test_accepts(self):
        self.assertEqual(wf.parse_time('03:00'), (3, 0, 0, 0))
        self.assertEqual(wf.parse_time('03:00:00'), (3, 0, 0, 0))
        self.assertEqual(wf.parse_time('23:59:59.250'), (23, 59, 59, 250))
        self.assertEqual(wf.parse_time('23:59:59.2'), (23, 59, 59, 200))
        self.assertEqual(wf.parse_time(' 7:05 '), (7, 5, 0, 0))

    def test_rejects(self):
        for bad in ('25:00', '12:60', '12:30:60', '', None, 'abc', '3', '03:0', 12):
            self.assertIsNone(wf.parse_time(bad), msg=repr(bad))

    def test_with_time(self):
        base = datetime.datetime(2026, 10, 27, 1, 2, 3, 4)
        out = wf.with_time(base, wf.parse_time('15:30:10.250'))
        self.assertEqual((out.hour, out.minute, out.second, out.microsecond),
                         (15, 30, 10, 250000))
        self.assertEqual(out.date(), base.date())


class RenderTests(unittest.TestCase):
    W, H = 400, 300

    def _render(self, when, **kw):
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.W, self.H)
        cr = cairo.Context(surface)
        wf.draw_watch(cr, self.W, self.H, when, **kw)
        return surface

    def test_render_0300(self):
        when = datetime.datetime(2026, 1, 1, 3, 0, 0)
        surface = self._render(when)  # (a) no exception

        r = 0.42 * min(self.W, self.H)
        cx, cy = self.W / 2.0, self.H / 2.0

        # (b) hour hand present on the LEFT (anticlockwise)
        light = _pixel(surface, round(cx - 0.3 * r), round(cy))
        self.assertTrue(all(c > 150 for c in light), msg='left pixel %r' % (light,))

        # (c) symmetric pixel on the RIGHT is plain face (dark)
        dark = _pixel(surface, round(cx + 0.3 * r), round(cy))
        self.assertTrue(all(c < 80 for c in dark), msg='right pixel %r' % (dark,))

        # (d) corner is pure THEME bg
        self.assertEqual(_pixel(surface, 0, 0), (0, 0, 0))

    def test_render_mirror_off_flips_dial_not_hands(self):
        when = datetime.datetime(2026, 1, 1, 3, 0, 0)
        surface = self._render(when, mirror=False)
        r = 0.42 * min(self.W, self.H)
        cx, cy = self.W / 2.0, self.H / 2.0
        # Hands are always mirrored: hour hand still on the left at 03:00.
        light = _pixel(surface, round(cx - 0.3 * r), round(cy))
        self.assertTrue(all(c > 150 for c in light), msg=repr(light))

    def test_render_options_do_not_raise(self):
        when = datetime.datetime(2026, 1, 1, 15, 30, 45, 250000)
        self._render(when, drift=(5.5, -3.25), show_seconds=False)
        self._render(when, mirror=False, drift=(0, 0), show_seconds=True)

    def test_render_leaves_context_state_restored(self):
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 50, 50)
        cr = cairo.Context(surface)
        cr.set_line_width(7.25)
        wf.draw_watch(cr, 50, 50, datetime.datetime(2026, 1, 1, 10, 10, 10))
        self.assertAlmostEqual(cr.get_line_width(), 7.25)

    def test_drift_moves_the_face(self):
        when = datetime.datetime(2026, 1, 1, 3, 0, 0)
        r = 0.42 * min(self.W, self.H)
        cx, cy = self.W / 2.0, self.H / 2.0
        # Shift the whole watch far enough right that the former hour-hand
        # pixel is now outside the face and therefore bg black.
        surface = self._render(when, drift=(0.9 * r, 0.0))
        self.assertEqual(_pixel(surface, round(cx - 0.9 * r), round(cy)), (0, 0, 0))


if __name__ == '__main__':
    unittest.main(verbosity=2)
