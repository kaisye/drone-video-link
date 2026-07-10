"""Unit tests for the heartbeat watchdog.

The watchdog is the one piece of flight-safety logic in the gateway, and its
behaviour is entirely about time: "declare the link lost 3 seconds after the
last heartbeat, once." A test that had to sleep 3 real seconds to check a
3-second timeout is a test nobody runs, so the watchdog takes an injectable
clock and these tests drive time by hand.

    python3 -m pytest tests/            # or: python3 tests/test_watchdog.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from gateway.watchdog import HeartbeatWatchdog, LinkState


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


def test_starts_waiting():
    wd = HeartbeatWatchdog(clock=FakeClock())
    assert wd.state is LinkState.WAITING
    # No beat yet is not a "lost" edge -- that is connect()'s timeout to report.
    assert wd.check() is LinkState.WAITING


def test_up_after_first_beat():
    wd = HeartbeatWatchdog(clock=FakeClock())
    wd.feed()
    assert wd.state is LinkState.UP
    assert wd.beats == 1


def test_stays_up_within_timeout():
    clk = FakeClock()
    wd = HeartbeatWatchdog(timeout_s=3.0, clock=clk)
    wd.feed()
    clk.advance(2.9)
    assert wd.check() is LinkState.UP


def test_lost_after_timeout():
    clk = FakeClock()
    wd = HeartbeatWatchdog(timeout_s=3.0, clock=clk)
    wd.feed()
    clk.advance(3.01)
    assert wd.check() is LinkState.LOST


def test_on_lost_fires_once_on_the_edge():
    clk = FakeClock()
    calls = []
    wd = HeartbeatWatchdog(timeout_s=3.0, clock=clk,
                           on_lost=lambda gap: calls.append(gap))
    wd.feed()
    clk.advance(3.5)
    wd.check()
    wd.check()          # still lost, but the callback must not fire again
    clk.advance(10)
    wd.check()
    assert len(calls) == 1
    assert calls[0] >= 3.0


def test_restore_fires_and_clears():
    clk = FakeClock()
    restored = []
    wd = HeartbeatWatchdog(timeout_s=3.0, clock=clk,
                           on_restored=lambda gap: restored.append(gap))
    wd.feed()
    clk.advance(3.5)
    assert wd.check() is LinkState.LOST
    wd.feed()           # link comes back
    assert wd.state is LinkState.UP
    assert len(restored) == 1


def test_exactly_at_timeout_is_not_yet_lost():
    # boundary: gap must exceed the timeout, not merely equal it.
    clk = FakeClock()
    wd = HeartbeatWatchdog(timeout_s=3.0, clock=clk)
    wd.feed()
    clk.advance(3.0)
    assert wd.check() is LinkState.UP


if __name__ == "__main__":
    # Run without pytest: call every test_* and report.
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL  {fn.__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    sys.exit(1 if failed else 0)
