'use strict';
// Run: node test/clockmath.test.js   (exit code 0 = pass)
const assert = require('node:assert/strict');
const path = require('node:path');
const ClockMath = require(path.join(__dirname, '..', 'js', 'clockmath.js'));

const PI = Math.PI;
const EPS = 1e-9;
let passed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log('ok   - ' + name);
  } catch (err) {
    failures.push({ name, err });
    console.log('FAIL - ' + name + '\n       ' + err.message);
  }
}

function approx(actual, expected, msg) {
  assert.ok(Math.abs(actual - expected) < EPS,
    (msg || '') + ' expected ' + expected + ' got ' + actual);
}

function at(h, m, s, ms) {
  return new Date(2026, 0, 1, h, m, s || 0, ms || 0);
}

// ---------------------------------------------------------------- exports
test('exports all contract functions', () => {
  for (const k of ['pointAt', 'handAngles', 'numeralTheta', 'driftOffset', 'parseTimeParam']) {
    assert.equal(typeof ClockMath[k], 'function', k);
  }
});

// ---------------------------------------------------------------- pointAt
test('pointAt mirror=true at PI/2 is LEFT of centre', () => {
  const p = ClockMath.pointAt(100, 100, 50, PI / 2, true);
  assert.ok(p.x < 100, 'x should be < cx, got ' + p.x);
  approx(p.x, 50); approx(p.y, 100);
});

test('pointAt mirror=false at PI/2 is RIGHT of centre', () => {
  const p = ClockMath.pointAt(100, 100, 50, PI / 2, false);
  assert.ok(p.x > 100, 'x should be > cx, got ' + p.x);
  approx(p.x, 150); approx(p.y, 100);
});

test('pointAt theta=0 points up regardless of mirror', () => {
  for (const mirror of [true, false]) {
    const p = ClockMath.pointAt(10, 20, 5, 0, mirror);
    approx(p.x, 10); approx(p.y, 15);
  }
});

test('pointAt theta=PI points down regardless of mirror', () => {
  for (const mirror of [true, false]) {
    const p = ClockMath.pointAt(10, 20, 5, PI, mirror);
    approx(p.x, 10); approx(p.y, 25);
  }
});

test('pointAt defaults to mirror=true', () => {
  const p = ClockMath.pointAt(0, 0, 1, PI / 2);
  approx(p.x, -1);
});

// ---------------------------------------------------------------- handAngles
test('handAngles 03:00:00 -> hour=PI/2, minute=0, second=0', () => {
  const a = ClockMath.handAngles(at(3, 0, 0));
  approx(a.hour, PI / 2, 'hour');
  approx(a.minute, 0, 'minute');
  approx(a.second, 0, 'second');
});

test('handAngles 12:00:00 -> hour=0', () => {
  approx(ClockMath.handAngles(at(12, 0, 0)).hour, 0);
  approx(ClockMath.handAngles(at(0, 0, 0)).hour, 0);
});

test('handAngles 15:30:00 -> hour = 2*PI*(3.5/12), minute = PI', () => {
  const a = ClockMath.handAngles(at(15, 30, 0));
  approx(a.hour, 2 * PI * (3.5 / 12), 'hour');
  approx(a.minute, PI, 'minute');
});

test('handAngles second increases with ms (sweeping)', () => {
  const a0 = ClockMath.handAngles(at(1, 2, 3, 0));
  const a1 = ClockMath.handAngles(at(1, 2, 3, 500));
  const a2 = ClockMath.handAngles(at(1, 2, 3, 999));
  assert.ok(a1.second > a0.second, 'ms=500 > ms=0');
  assert.ok(a2.second > a1.second, 'ms=999 > ms=500');
  approx(a1.second - a0.second, 2 * PI * 0.5 / 60);
});

test('handAngles exact formulas at 10:20:30.250', () => {
  const a = ClockMath.handAngles(at(10, 20, 30, 250));
  const sec = 30.25;
  approx(a.second, 2 * PI * sec / 60);
  approx(a.minute, 2 * PI * (20 + sec / 60) / 60);
  approx(a.hour, 2 * PI * (10 + 20 / 60 + 30 / 3600) / 12);
});

// ---------------------------------------------------------------- numeralTheta
test('numeralTheta(12)=0 and numeralTheta(3)=PI/2', () => {
  approx(ClockMath.numeralTheta(12), 0);
  approx(ClockMath.numeralTheta(3), PI / 2);
  approx(ClockMath.numeralTheta(6), PI);
  approx(ClockMath.numeralTheta(9), 3 * PI / 2);
});

// ---------------------------------------------------------------- anticlockwise property
test('hour hand TIP at 03:00 is LEFT of centre (anticlockwise)', () => {
  const a = ClockMath.handAngles(at(3, 0, 0));
  const tip = ClockMath.pointAt(200, 200, 100, a.hour, true);
  assert.ok(tip.x < 200, 'tip.x=' + tip.x);
  approx(tip.y, 200);
});

test('hour hand TIP at 09:00 is RIGHT of centre (anticlockwise)', () => {
  const a = ClockMath.handAngles(at(9, 0, 0));
  const tip = ClockMath.pointAt(200, 200, 100, a.hour, true);
  assert.ok(tip.x > 200, 'tip.x=' + tip.x);
  approx(tip.y, 200);
});

test('mirrored dial numeral 3 lands where mirrored hour hand points at 03:00', () => {
  const a = ClockMath.handAngles(at(3, 0, 0));
  const hand = ClockMath.pointAt(0, 0, 1, a.hour, true);
  const num = ClockMath.pointAt(0, 0, 1, ClockMath.numeralTheta(3), true);
  approx(hand.x, num.x); approx(hand.y, num.y);
});

// ---------------------------------------------------------------- driftOffset
test('driftOffset(0, 0) is {0,0}', () => {
  const d = ClockMath.driftOffset(0, 0);
  assert.equal(d.dx, 0);
  assert.equal(d.dy, 0);
});

test('driftOffset is {0,0} for any t when amplitude is 0', () => {
  for (let t = 0; t <= 600000; t += 7331) {
    const d = ClockMath.driftOffset(t, 0);
    assert.equal(d.dx, 0); assert.equal(d.dy, 0);
  }
});

test('driftOffset magnitude never exceeds amplitude over a sweep', () => {
  const amp = 40;
  let maxMag = 0;
  for (let t = 0; t <= 20 * 60 * 1000; t += 250) { // 20 minutes, 4 Hz
    const d = ClockMath.driftOffset(t, amp);
    const mag = Math.hypot(d.dx, d.dy);
    assert.ok(Number.isFinite(mag));
    assert.ok(mag <= amp + 1e-9, 't=' + t + ' mag=' + mag);
    if (mag > maxMag) maxMag = mag;
  }
  assert.ok(maxMag > amp * 0.5, 'drift should actually move, max=' + maxMag);
});

test('driftOffset actually changes over time (slow path)', () => {
  const d0 = ClockMath.driftOffset(0, 10);
  const d1 = ClockMath.driftOffset(20000, 10);
  assert.ok(Math.hypot(d1.dx - d0.dx, d1.dy - d0.dy) > 0.1);
});

// ---------------------------------------------------------------- parseTimeParam
test('parseTimeParam accepts "03:00"', () => {
  assert.deepEqual(ClockMath.parseTimeParam('03:00'), { h: 3, m: 0, s: 0, ms: 0 });
});

test('parseTimeParam accepts "03:00:00"', () => {
  assert.deepEqual(ClockMath.parseTimeParam('03:00:00'), { h: 3, m: 0, s: 0, ms: 0 });
});

test('parseTimeParam accepts "23:59:59.250"', () => {
  assert.deepEqual(ClockMath.parseTimeParam('23:59:59.250'), { h: 23, m: 59, s: 59, ms: 250 });
});

test('parseTimeParam accepts short fraction "01:02:03.5" as 500 ms', () => {
  assert.deepEqual(ClockMath.parseTimeParam('01:02:03.5'), { h: 1, m: 2, s: 3, ms: 500 });
});

test('parseTimeParam rejects bad input', () => {
  for (const bad of ['25:00', 'abc', '', null, undefined, '12:60', '12:00:60', '1200', '12', 42, {}]) {
    assert.equal(ClockMath.parseTimeParam(bad), null, 'should reject ' + JSON.stringify(bad));
  }
});

// ---------------------------------------------------------------- summary
console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
if (failures.length) {
  for (const f of failures) console.error('  ' + f.name + ': ' + f.err.message);
  process.exit(1);
}
