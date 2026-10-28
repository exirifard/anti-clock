/* dial.js - draws the static watch face.
 * Global: drawDial(ctx, cx, cy, r, theme, mirror)
 * Every position comes from ClockMath.pointAt so the mirror flag is honoured.
 * Pure drawing: no state, no listeners. Draws in CSS pixels (ctx pre-scaled by main.js).
 */
function drawDial(ctx, cx, cy, r, theme, mirror) {
  if (mirror === undefined) { mirror = true; }
  var CM = ClockMath;
  var TAU = Math.PI * 2;
  var n, theta, p, q, len, w;

  ctx.save();
  ctx.lineCap = 'round';

  /* Face */
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, TAU);
  ctx.fillStyle = theme.face;
  ctx.fill();

  /* Outer bezel ring, centred on the rim */
  w = 0.045 * r;
  ctx.beginPath();
  ctx.arc(cx, cy, r - w / 2, 0, TAU);
  ctx.lineWidth = w;
  ctx.strokeStyle = theme.bezel;
  ctx.stroke();

  /* Thin inner highlight ring just inside the bezel */
  ctx.beginPath();
  ctx.arc(cx, cy, r - w - 0.006 * r, 0, TAU);
  ctx.lineWidth = Math.max(1, 0.008 * r);
  ctx.strokeStyle = theme.bezelHighlight;
  ctx.stroke();

  /* Ticks: 60 minute ticks (short, thin) and 12 hour ticks (longer, thicker).
   * Major ticks end at tickOuter - 0.06r = 0.865r so they stay clear of the numerals. */
  var tickOuter = r - w - 0.03 * r;
  for (n = 0; n < 60; n++) {
    theta = TAU * n / 60;
    var major = (n % 5 === 0);
    len = major ? 0.06 * r : 0.045 * r;
    p = CM.pointAt(cx, cy, tickOuter, theta, mirror);
    q = CM.pointAt(cx, cy, tickOuter - len, theta, mirror);
    ctx.beginPath();
    ctx.moveTo(p.x, p.y);
    ctx.lineTo(q.x, q.y);
    ctx.lineWidth = Math.max(1, (major ? 0.02 : 0.008) * r);
    ctx.strokeStyle = major ? theme.tickMajor : theme.tick;
    ctx.stroke();
  }

  /* Numerals 1..12 at 0.70 r (inside the tick ring, no overlap), glyphs drawn upright (never flipped) */
  var px = Math.round(0.16 * r);
  ctx.font = theme.font.replace('{px}', String(px));
  ctx.fillStyle = theme.numeral;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (n = 1; n <= 12; n++) {
    p = CM.pointAt(cx, cy, 0.70 * r, CM.numeralTheta(n), mirror);
    ctx.fillText(String(n), p.x, p.y);
  }

  ctx.restore();
}
