/*
 * clockmath.js - pure geometry/time math for Anti-Clock.
 *
 * Works in the browser as the global `ClockMath` and in node via
 * `module.exports` (see dual export wrapper at the bottom).
 *
 * ANGLE CONTRACT
 *   theta is in radians, measured from 12 o'clock, increasing CLOCKWISE on a
 *   NORMAL clock. A normal clock point is x = cx + r*sin(theta),
 *   y = cy - r*cos(theta). The watch runs anticlockwise by mirroring across
 *   the vertical axis (mirror=true -> x = cx - r*sin(theta)).
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  }
  root.ClockMath = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var TWO_PI = 2 * Math.PI;

  /**
   * Point on a circle of radius r centred at (cx, cy) at angle theta.
   * theta is a NORMAL-clock angle (radians, clockwise-positive from 12).
   * mirror=true (default) flips across the vertical axis so increasing theta
   * moves anticlockwise on screen.
   */
  function pointAt(cx, cy, r, theta, mirror) {
    if (mirror === undefined) { mirror = true; }
    var s = r * Math.sin(theta);
    return {
      x: mirror ? cx - s : cx + s,
      y: cy - r * Math.cos(theta)
    };
  }

  /**
   * NORMAL-clock hand angles (radians, clockwise-positive) for a Date.
   * Hands are drawn with pointAt(..., mirror=true) so they sweep anticlockwise.
   */
  function handAngles(date) {
    var h = date.getHours();
    var m = date.getMinutes();
    var s = date.getSeconds();
    var ms = date.getMilliseconds();
    var sec = s + ms / 1000;
    return {
      second: TWO_PI * sec / 60,
      minute: TWO_PI * (m + sec / 60) / 60,
      hour: TWO_PI * ((h % 12) + m / 60 + s / 3600) / 12
    };
  }

  /** NORMAL-clock angle of numeral n (1..12); 12 -> 0 (top). */
  function numeralTheta(n) {
    return TWO_PI * (n % 12) / 12;
  }

  /**
   * Slow Lissajous offset for burn-in protection.
   * Periods ~97 s (x) and ~131 s (y); magnitude never exceeds `amplitude`
   * because each axis is scaled by amplitude/sqrt(2).
   */
  function driftOffset(tMs, amplitude) {
    if (!amplitude) { return { dx: 0, dy: 0 }; }
    var t = tMs / 1000;
    var a = amplitude / Math.SQRT2;
    return {
      dx: a * Math.sin(TWO_PI * t / 97),
      dy: a * Math.sin(TWO_PI * t / 131 + Math.PI / 3)
    };
  }

  /**
   * Parse "HH:MM", "HH:MM:SS" or "HH:MM:SS.mmm" into {h, m, s, ms}.
   * Returns null on bad input or out-of-range fields.
   */
  function parseTimeParam(str) {
    if (typeof str !== 'string') { return null; }
    var m = /^\s*(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\s*$/.exec(str);
    if (!m) { return null; }
    var h = parseInt(m[1], 10);
    var mi = parseInt(m[2], 10);
    var s = m[3] === undefined ? 0 : parseInt(m[3], 10);
    var ms = m[4] === undefined ? 0 : parseInt((m[4] + '00').slice(0, 3), 10);
    if (h > 23 || mi > 59 || s > 59) { return null; }
    return { h: h, m: mi, s: s, ms: ms };
  }

  return {
    TWO_PI: TWO_PI,
    pointAt: pointAt,
    handAngles: handAngles,
    numeralTheta: numeralTheta,
    driftOffset: driftOffset,
    parseTimeParam: parseTimeParam
  };
});
