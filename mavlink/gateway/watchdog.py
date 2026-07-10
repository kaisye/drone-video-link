"""Heartbeat watchdog.

MAVLink flight controllers emit HEARTBEAT at 1 Hz. The convention, and
ArduPilot's own GCS-failsafe default, is that missing it for ~3 seconds means
the link is down. This is real flight-safety logic: on the aircraft side, losing
the GCS heartbeat is what triggers a failsafe (RTL/land). The gateway is the GCS
side of that same contract, so it has to notice the loss just as promptly.

The watchdog is deliberately not a thread. It is a small state machine ticked by
whoever owns the receive loop, so there is no shared mutable state between
threads and no lock. `feed()` on every heartbeat, `check()` on every tick (or
every message); the transition callbacks fire exactly once per edge.
"""
from __future__ import annotations

import time
from enum import Enum
from typing import Callable, Optional


class LinkState(Enum):
    WAITING = "WAITING"      # nothing seen yet
    UP = "UP"                # heartbeat within the timeout
    LOST = "LOST"            # timeout exceeded


class HeartbeatWatchdog:
    """Edge-triggered link-health tracker.

    timeout_s defaults to 3.0: three missed 1 Hz beats. `clock` is injectable so
    tests can drive time forward without sleeping -- the whole point of a
    watchdog is behaviour over time, and a test that has to sleep 3 real seconds
    to check a 3-second timeout is a test nobody runs.
    """

    def __init__(self,
                 timeout_s: float = 3.0,
                 clock: Callable[[], float] = time.monotonic,
                 on_lost: Optional[Callable[[float], None]] = None,
                 on_restored: Optional[Callable[[float], None]] = None):
        self.timeout_s = timeout_s
        self._clock = clock
        self._on_lost = on_lost
        self._on_restored = on_restored

        self._last_beat: Optional[float] = None
        self._state = LinkState.WAITING
        self._beats = 0

    @property
    def state(self) -> LinkState:
        return self._state

    @property
    def beats(self) -> int:
        return self._beats

    def since_last_beat(self) -> Optional[float]:
        """Seconds since the last heartbeat, or None if none seen yet."""
        if self._last_beat is None:
            return None
        return self._clock() - self._last_beat

    def feed(self) -> None:
        """Record a heartbeat. Fires on_restored if we were LOST."""
        self._last_beat = self._clock()
        self._beats += 1
        if self._state is LinkState.LOST:
            # monotonic clock, so the argument is a duration-of-outage the caller
            # can log; here it is 0 because the beat just landed.
            if self._on_restored:
                self._on_restored(0.0)
        self._state = LinkState.UP

    def check(self) -> LinkState:
        """Re-evaluate against the clock. Fires on_lost on the WAITING/UP -> LOST
        edge, once. Returns the current state.
        """
        if self._last_beat is None:
            return self._state  # still WAITING; a missing link that never came
                                # up is the caller's connect() timeout to report,
                                # not a "lost" edge.
        gap = self._clock() - self._last_beat
        if gap > self.timeout_s:
            if self._state is not LinkState.LOST:
                self._state = LinkState.LOST
                if self._on_lost:
                    self._on_lost(gap)
        return self._state
