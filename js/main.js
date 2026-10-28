/*
 * main.js - canvas setup, animation loop, drift, URL params, exit-on-input.
 *
 * Depends on globals defined by earlier classic <script> tags:
 *   ClockMath (js/clockmath.js), drawDial (js/dial.js), drawHands (js/hands.js)
 *
 * URL params:
 *   ?time=HH:MM[:SS[.mmm]]  freeze the displayed time (drift still animates)
 *   ?mirror=0               normal dial under anticlockwise hands
 *   ?drift=0                disable burn-in drift
 *   ?seconds=0              hide the second hand
 *   ?smooth=0               ticking (whole-second) second hand instead of sweeping
 *   ?exit=0                 keep running on input (for previewing in a normal browser)
 */
(function () {
  'use strict';

  var THEME = {
    bg: '#000000',
    face: '#111317',
    bezel: '#2a2e36',
    bezelHighlight: '#4a505c',
    tick: '#9aa3b2',
    tickMajor: '#e6e9ef',
    numeral: '#e6e9ef',
    hour: '#e6e9ef',
    minute: '#e6e9ef',
    second: '#e0452e',
    cap: '#e6e9ef',
    font: '500 {px}px "Segoe UI", "Noto Sans", "DejaVu Sans", system-ui, sans-serif'
  };

  var MOUSE_GRACE_MS = 1500;   // ignore mousemove this long after load
  var MOUSE_THRESHOLD_PX = 4;  // movement from first observed position that counts as input

  document.title = 'Anti-Clock';

  var canvas = document.getElementById('clock');
  if (!canvas) {
    return;
  }
  var ctx = canvas.getContext('2d');

  /* ---------- URL params ---------- */

  var params = new URLSearchParams(window.location.search);

  function flag(name, defaultValue) {
    if (!params.has(name)) {
      return defaultValue;
    }
    var v = String(params.get(name)).trim().toLowerCase();
    if (v === '0' || v === 'false' || v === 'no' || v === 'off') {
      return false;
    }
    if (v === '' || v === '1' || v === 'true' || v === 'yes' || v === 'on') {
      return true;
    }
    return defaultValue;
  }

  var fixedTime = params.has('time') ? ClockMath.parseTimeParam(params.get('time')) : null;
  var mirrorDial = flag('mirror', true);
  var driftEnabled = flag('drift', true);
  var showSeconds = flag('seconds', true);
  var smoothSeconds = flag('smooth', true);
  var exitOnInput = flag('exit', true);

  /* ---------- canvas sizing ---------- */

  var width = 0;
  var height = 0;
  var dpr = 1;

  function resize() {
    dpr = window.devicePixelRatio || 1;
    width = window.innerWidth;
    height = window.innerHeight;
    canvas.width = Math.max(1, Math.round(width * dpr));
    canvas.height = Math.max(1, Math.round(height * dpr));
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    // Draw in CSS pixels; the transform maps them to device pixels.
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  window.addEventListener('resize', resize);

  /* ---------- time source ---------- */

  function now() {
    return (window.performance && typeof window.performance.now === 'function')
      ? window.performance.now()
      : Date.now();
  }

  function currentDate() {
    var d = new Date();
    if (fixedTime) {
      d.setHours(fixedTime.h, fixedTime.m, fixedTime.s, fixedTime.ms);
    } else if (!smoothSeconds) {
      d.setMilliseconds(0);
    }
    return d;
  }

  /* ---------- animation loop ---------- */

  function frame() {
    var date = currentDate();
    var angles = ClockMath.handAngles(date);
    if (!showSeconds) {
      angles.second = null;
    }

    var minDim = Math.min(width, height);
    var r = 0.42 * minDim;
    var cx = width / 2;
    var cy = height / 2;

    var dx = 0;
    var dy = 0;
    if (driftEnabled) {
      var drift = ClockMath.driftOffset(now(), 0.04 * minDim);
      dx = drift.dx;
      dy = drift.dy;
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = THEME.bg;
    ctx.fillRect(0, 0, width, height);

    drawDial(ctx, cx + dx, cy + dy, r, THEME, mirrorDial);
    drawHands(ctx, cx + dx, cy + dy, r, angles, THEME);

    window.requestAnimationFrame(frame);
  }

  /* ---------- exit on input ---------- */

  var exited = false;

  function exit() {
    if (exited) {
      return;
    }
    exited = true;
    // Chrome allows window.close() in a kiosk window with a single history
    // entry. run.sh also kills Chrome via idle-time polling as a backstop.
    window.close();
  }

  var loadedAt = now();
  var firstMouse = null;

  function onMouseMove(e) {
    if (now() - loadedAt < MOUSE_GRACE_MS) {
      return;
    }
    if (firstMouse === null) {
      firstMouse = { x: e.clientX, y: e.clientY };
      return;
    }
    var mx = e.clientX - firstMouse.x;
    var my = e.clientY - firstMouse.y;
    if (mx * mx + my * my >= MOUSE_THRESHOLD_PX * MOUSE_THRESHOLD_PX) {
      exit();
    }
  }

  if (exitOnInput) {
    window.addEventListener('keydown', exit);
    window.addEventListener('mousedown', exit);
    window.addEventListener('wheel', exit, { passive: true });
    window.addEventListener('touchstart', exit, { passive: true });
    window.addEventListener('mousemove', onMouseMove);
  }

  /* ---------- start ---------- */

  resize();
  window.requestAnimationFrame(frame);
})();
