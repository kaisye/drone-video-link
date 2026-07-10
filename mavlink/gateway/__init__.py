"""MAVLink telemetry and control gateway for a drone ground station.

The gateway sits between a flight controller (ArduPilot, real or SITL) and
whatever consumes its data. It does three things, in order of how much they
matter when something goes wrong:

    watchdog    notice that the link is gone, within one failsafe interval
    telemetry   parse, scale to SI, and log
    commands    arm / takeoff / land, and *verify* each one against COMMAND_ACK

MAVLink is a two-way asymmetric protocol. Telemetry is streamed by the flight
controller without being asked. Commands are request/ack: send COMMAND_LONG,
wait for COMMAND_ACK. Fire-and-forget is not a shortcut, it is a bug.
"""

__all__ = ["connection", "watchdog", "telemetry", "commands"]
