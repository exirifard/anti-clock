#!/usr/bin/env python3
"""
anticlock-watch.py - xscreensaver "hack" that draws Anti-Clock.

Modes
  EMBEDDED    -window-id ID / --window-id ID, or env XSCREENSAVER_WINDOW set:
              draw into the X window xscreensaver (or its settings preview)
              hands us, using a Gtk.Plug child window. No toplevel, no grabs.
  STANDALONE  otherwise (or --window): a normal 800x500 Gtk.Window titled
              "Anti-Clock" (--fullscreen for full screen). Escape or
              q quits.
  ONCE        --once FILE.png: render one frame to a PNG with cairo only, no
              GTK, no display needed. Test hook.

All drawing/geometry lives in watchface.py next to this file (cairo only).
xscreensaver stops a hack with SIGTERM; SIGTERM/SIGINT/SIGHUP all end the
GTK main loop cleanly. Nothing is written to stdout; errors go to stderr.
"""

import os

# Keep the accessibility bus out of the picture (no dbus chatter, no delays
# under the locked screen). Must be set before gi is imported.
os.environ.setdefault('NO_AT_BRIDGE', '1')

import argparse  # noqa: E402
import datetime  # noqa: E402
import signal  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    import watchface  # noqa: E402
    _WATCHFACE_ERROR = None
except ImportError as _exc:  # pragma: no cover - reported after arg parsing
    watchface = None
    _WATCHFACE_ERROR = _exc

PROG = 'anticlock-watch.py'
DEFAULT_ONCE_SIZE = (1280, 800)
STANDALONE_SIZE = (800, 500)
DEFAULT_FPS = 15
MAX_FPS = 120
DRIFT_FRACTION = 0.04          # drift amplitude = 0.04 * min(width, height)
PARENT_POLL_MS = 1000          # embedded mode: how often to re-check parent size


def eprint(*args):
    print(*args, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# argument helpers
# ---------------------------------------------------------------------------

def parse_size(text):
    """'WxH' -> (w, h), both >= 1."""
    try:
        w_str, h_str = text.lower().split('x', 1)
        w, h = int(w_str), int(h_str)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "size must look like WIDTHxHEIGHT, e.g. 1280x800 (got %r)" % text)
    if w < 1 or h < 1:
        raise argparse.ArgumentTypeError("size must be at least 1x1 (got %r)" % text)
    return (w, h)


def parse_xid(text):
    """Window id as decimal or 0x hex -> int."""
    try:
        xid = int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "window id must be decimal or 0x hex (got %r)" % text)
    if xid <= 0:
        raise argparse.ArgumentTypeError("window id must be positive (got %r)" % text)
    return xid


def parse_fps(text):
    try:
        fps = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("fps must be an integer (got %r)" % text)
    if fps < 1 or fps > MAX_FPS:
        raise argparse.ArgumentTypeError("fps must be 1..%d (got %d)" % (MAX_FPS, fps))
    return fps


def build_parser():
    p = argparse.ArgumentParser(
        prog=PROG,
        allow_abbrev=False,
        description='Anti-Clock - an xscreensaver hack (and standalone clock).',
        epilog=(
            'Embedded mode is chosen when -window-id/--window-id is given or the '
            'environment variable XSCREENSAVER_WINDOW is set (that is how '
            'xscreensaver and xscreensaver-settings run hacks). Otherwise a normal '
            'window is opened. --once renders a single PNG without GTK or a display.'
        ))
    p.add_argument('-root', '--root', action='store_true',
                   help='accepted and ignored (xscreensaver convention)')
    p.add_argument('-window-id', '--window-id', metavar='ID', type=parse_xid,
                   help='X window id (decimal or 0x hex) to draw into; implies embedded mode')
    p.add_argument('--window', action='store_true',
                   help='force standalone window mode even if XSCREENSAVER_WINDOW is set')
    p.add_argument('--fullscreen', action='store_true',
                   help='standalone mode: make the window full screen')
    p.add_argument('--time', metavar='HH:MM[:SS[.mmm]]',
                   help='freeze the displayed time (drift still animates)')
    p.add_argument('--mirror', type=int, choices=(0, 1), default=1, metavar='0|1',
                   help='1 = mirrored dial so the anticlockwise hands read correctly '
                        '(default); 0 = normal dial')
    p.add_argument('--no-drift', action='store_true',
                   help='disable the slow burn-in drift (amplitude otherwise '
                        '%.2f*min(width,height))' % DRIFT_FRACTION)
    p.add_argument('--no-seconds', action='store_true', help='hide the second hand')
    p.add_argument('--fps', type=parse_fps, default=DEFAULT_FPS, metavar='N',
                   help='frames per second, 1..%d (default %d)' % (MAX_FPS, DEFAULT_FPS))
    p.add_argument('--once', metavar='FILE.png',
                   help='render one frame to FILE.png and exit (no GTK, no display)')
    p.add_argument('--size', type=parse_size, default=DEFAULT_ONCE_SIZE, metavar='WxH',
                   help='image size for --once (default %dx%d)' % DEFAULT_ONCE_SIZE)
    return p


# ---------------------------------------------------------------------------
# the model: what time to show, where the face sits
# ---------------------------------------------------------------------------

class WatchState:
    """Pure state -> frame parameters. Drawing itself is watchface.draw_watch."""

    def __init__(self, fixed_time, mirror, drift_enabled, show_seconds):
        self.fixed_time = fixed_time        # (h, m, s, ms) or None
        self.mirror = bool(mirror)
        self.drift_enabled = bool(drift_enabled)
        self.show_seconds = bool(show_seconds)
        self.started = time.monotonic()

    def when(self):
        now = datetime.datetime.now()
        if self.fixed_time is None:
            return now
        h, m, s, ms = self.fixed_time
        return now.replace(hour=h, minute=m, second=s, microsecond=ms * 1000)

    def drift(self, width, height):
        if not self.drift_enabled:
            return (0.0, 0.0)
        amplitude = DRIFT_FRACTION * min(width, height)
        dx, dy = watchface.drift_offset(time.monotonic() - self.started, amplitude)
        return (float(dx), float(dy))

    def draw(self, cr, width, height):
        watchface.draw_watch(cr, width, height, self.when(),
                             mirror=self.mirror,
                             drift=self.drift(width, height),
                             show_seconds=self.show_seconds)


# ---------------------------------------------------------------------------
# --once: cairo only
# ---------------------------------------------------------------------------

def render_once(state, path, size):
    import cairo
    width, height = size
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    cr = cairo.Context(surface)
    state.draw(cr, width, height)
    surface.flush()
    surface.write_to_png(path)
    return 0


# ---------------------------------------------------------------------------
# GTK modes
# ---------------------------------------------------------------------------

def run_gtk(state, xid, fps, fullscreen):
    """xid is an int for embedded mode, None for standalone. Returns exit code."""
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        gi.require_version('Gdk', '3.0')
        gi.require_version('GdkX11', '3.0')
        from gi.repository import Gtk, Gdk, GdkX11, GLib
    except Exception as exc:  # ImportError, ValueError (missing typelib), RuntimeError (no display)
        eprint('%s: cannot initialise GTK: %s' % (PROG, exc))
        return 1

    # ---- clean shutdown on the signals xscreensaver (and terminals) send ----
    def quit_on_signal(*_args):
        Gtk.main_quit()
        return GLib.SOURCE_REMOVE

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, signum, quit_on_signal)
        except Exception:
            signal.signal(signum, lambda *_a: Gtk.main_quit())

    # ---- drawing ----
    def on_draw(widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        if w > 0 and h > 0:
            state.draw(cr, w, h)
        return True

    da = Gtk.DrawingArea()
    da.connect('draw', on_draw)

    frame_ms = max(1, int(round(1000.0 / fps)))

    def tick():
        # The first draw only happens after a queue_draw, so this timer is
        # required even for a frozen --time face.
        da.queue_draw()
        return GLib.SOURCE_CONTINUE

    if xid is not None:
        # ---------------- EMBEDDED (proven technique) ----------------
        disp = Gdk.Display.get_default()
        if disp is None:
            eprint('%s: no X display' % PROG)
            return 1
        try:
            parent = GdkX11.X11Window.foreign_new_for_display(disp, xid)
        except TypeError:  # PyGObject raises "constructor returned NULL"
            parent = None
        if parent is None:
            eprint('%s: window 0x%x does not exist' % (PROG, xid))
            return 1
        # GDK caches a foreign window's geometry and only refreshes it from
        # ConfigureNotify, which it does not select on foreign windows by
        # default; ask for StructureNotify so the size poll below sees changes
        # (and is_destroyed() becomes true when the parent goes away).
        try:
            parent.set_events(parent.get_events() | Gdk.EventMask.STRUCTURE_MASK)
        except Exception:
            pass
        pw, ph = parent.get_width(), parent.get_height()
        # The embedder may destroy its window (and so ours) without SIGTERM;
        # make X errors non-fatal so we leave via the plug's 'destroy' (exit 0)
        # instead of GDK's fatal BadWindow abort. Never popped on purpose.
        try:
            GdkX11.X11Display.error_trap_push(disp)
        except Exception:
            pass
        plug = Gtk.Plug.new(xid)
        plug.set_default_size(pw, ph)
        plug.add(da)
        plug.connect('destroy', lambda *_a: Gtk.main_quit())
        plug.show_all()
        # A GtkPlug follows XEMBED and leaves mapping its X window to the
        # embedder (a GtkSocket). xscreensaver's window is a plain X window,
        # so without this the plug stays IsUnMapped and nothing is visible.
        gdkwin = plug.get_window()
        if gdkwin is None:
            eprint('%s: plug has no GdkWindow' % PROG)
            return 1
        gdkwin.show()

        last_size = [(pw, ph)]

        def poll_parent():
            try:
                if parent.is_destroyed():
                    Gtk.main_quit()
                    return GLib.SOURCE_REMOVE
                w, h = parent.get_width(), parent.get_height()
            except Exception:
                Gtk.main_quit()
                return GLib.SOURCE_REMOVE
            if (w, h) != last_size[0] and w > 0 and h > 0:
                last_size[0] = (w, h)
                try:
                    # Resize at the X level (Gtk.Window.resize() is ignored
                    # for a plug without a socket); GTK then follows the
                    # ConfigureNotify and reallocates the drawing area.
                    gdkwin.resize(w, h)
                except Exception:
                    Gtk.main_quit()
                    return GLib.SOURCE_REMOVE
            return GLib.SOURCE_CONTINUE

        GLib.timeout_add(PARENT_POLL_MS, poll_parent)
    else:
        # ---------------- STANDALONE ----------------
        win = Gtk.Window(title='Anti-Clock')
        win.set_default_size(*STANDALONE_SIZE)
        try:
            css = Gtk.CssProvider()
            css.load_from_data(b'window, drawingarea { background-color: #000000; }')
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        except Exception:
            pass  # the draw handler paints the background anyway

        def on_key(_widget, event):
            if event.keyval in (Gdk.KEY_Escape, Gdk.KEY_q, Gdk.KEY_Q):
                Gtk.main_quit()
                return True
            return False

        win.connect('key-press-event', on_key)
        win.connect('destroy', lambda *_a: Gtk.main_quit())
        win.add(da)
        if fullscreen:
            win.fullscreen()

            def hide_cursor(widget):
                try:
                    gdkwin = widget.get_window()
                    gdkwin.set_cursor(Gdk.Cursor.new_from_name(gdkwin.get_display(), 'none'))
                except Exception:
                    pass
            win.connect('realize', hide_cursor)
        win.show_all()

    GLib.timeout_add(frame_ms, tick)
    Gtk.main()
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = build_parser()
    args, unknown = parser.parse_known_args(argv)
    if unknown:
        # A screensaver hack should keep running rather than die on an
        # unexpected flag; say so on stderr and carry on.
        eprint('%s: ignoring unrecognised arguments: %s' % (PROG, ' '.join(unknown)))

    if watchface is None:
        eprint('%s: cannot import watchface.py from %s: %s' % (PROG, HERE, _WATCHFACE_ERROR))
        return 1

    fixed_time = None
    if args.time is not None:
        fixed_time = watchface.parse_time(args.time)
        if fixed_time is None:
            parser.error("--time: expected HH:MM[:SS[.mmm]] with valid ranges, got %r" % args.time)

    state = WatchState(fixed_time=fixed_time,
                       mirror=(args.mirror == 1),
                       drift_enabled=not args.no_drift,
                       show_seconds=not args.no_seconds)

    if args.once:
        try:
            return render_once(state, args.once, args.size)
        except Exception as exc:
            eprint('%s: --once failed: %s' % (PROG, exc))
            return 1

    # Mode selection: explicit --window-id > --window > XSCREENSAVER_WINDOW > standalone.
    xid = args.window_id
    if xid is None and not args.window:
        env_xid = os.environ.get('XSCREENSAVER_WINDOW')
        if env_xid:
            try:
                xid = parse_xid(env_xid.strip())
            except argparse.ArgumentTypeError as exc:
                eprint('%s: bad XSCREENSAVER_WINDOW=%r: %s' % (PROG, env_xid, exc))
                return 1

    return run_gtk(state, xid, args.fps, args.fullscreen)


if __name__ == '__main__':
    sys.exit(main())
