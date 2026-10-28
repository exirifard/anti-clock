/* hands.js - draws the hour, minute and second hands plus the center cap.
 *
 * Global: drawHands(ctx, cx, cy, r, angles, theme)
 *   angles = { hour, minute, second } are NORMAL-clock thetas (radians,
 *   clockwise-positive, 0 at 12 o'clock) from ClockMath.handAngles(date).
 *   Every tip / tail position comes from ClockMath.pointAt(..., mirror=true)
 *   so the hands sweep ANTICLOCKWISE on screen.
 *
 * Pure drawing: no state, saves/restores ctx, draws in CSS pixels
 * (main.js has already scaled ctx for devicePixelRatio).
 */
(function (root) {
  'use strict';

  var PI = Math.PI;

  // Hand geometry as fractions of r.
  var HOUR   = { len: 0.52, width: 0.06,  tail: 0.12 };
  var MINUTE = { len: 0.76, width: 0.045, tail: 0.14 };
  var SECOND = { len: 0.86, width: 0.015, tail: 0.2 };

  function mirroredPoint(cx, cy, len, theta) {
    return ClockMath.pointAt(cx, cy, len, theta, true);
  }

  // Draws one hand as a single stroked line from tail (theta + PI) to tip.
  function strokeHand(ctx, cx, cy, r, theta, spec, color) {
    var tip = mirroredPoint(cx, cy, spec.len * r, theta);
    var tail = mirroredPoint(cx, cy, spec.tail * r, theta + PI);
    ctx.beginPath();
    ctx.moveTo(tail.x, tail.y);
    ctx.lineTo(tip.x, tip.y);
    ctx.lineWidth = Math.max(1, spec.width * r);
    ctx.strokeStyle = color;
    ctx.stroke();
    return { tip: tip, tail: tail };
  }

  function drawHands(ctx, cx, cy, r, angles, theme) {
    if (!ctx || !angles || !theme) { return; }

    ctx.save();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    // Subtle shadow under all hands.
    ctx.shadowColor = 'rgba(0,0,0,0.5)';
    ctx.shadowBlur = 0.02 * r;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 0.006 * r;

    // Hour hand.
    strokeHand(ctx, cx, cy, r, angles.hour, HOUR, theme.hour);

    // Minute hand.
    strokeHand(ctx, cx, cy, r, angles.minute, MINUTE, theme.minute);

    // Second hand (optional).
    var hasSecond = angles.second !== null && angles.second !== undefined;
    if (hasSecond) {
      var sec = strokeHand(ctx, cx, cy, r, angles.second, SECOND, theme.second);
      // Counterweight circle sitting on the tail, slightly inside the tail end.
      var cwRadius = Math.max(1.5, 0.03 * r);
      var cw = mirroredPoint(cx, cy, SECOND.tail * r - cwRadius, angles.second + PI);
      ctx.beginPath();
      ctx.arc(cw.x, cw.y, cwRadius, 0, 2 * PI);
      ctx.fillStyle = theme.second;
      ctx.fill();
      void sec;
    }

    // Center cap: no shadow for a crisp disc.
    ctx.shadowColor = 'rgba(0,0,0,0)';
    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    var capRadius = 0.045 * r;
    ctx.beginPath();
    ctx.arc(cx, cy, capRadius, 0, 2 * PI);
    ctx.fillStyle = theme.cap;
    ctx.fill();

    ctx.beginPath();
    ctx.arc(cx, cy, capRadius * 0.45, 0, 2 * PI);
    ctx.fillStyle = theme.second;
    ctx.fill();

    ctx.restore();
  }

  root.drawHands = drawHands;
})(typeof self !== 'undefined' ? self : this);
