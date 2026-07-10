"""Publish telemetry snapshots to MQTT. [P2]

Why this exists: the job description asks for embedded-to-cloud integration over
MQTT, and a ground station is exactly the seam where a drone's telemetry leaves
the RF link and joins a normal network. One topic, JSON payloads, retained last
value -- enough to show the pattern without pretending to be a fleet backend.

paho-mqtt is an optional dependency. If it is not installed, importing this
module raises, and cli.py degrades to a warning rather than failing the whole
gateway -- telemetry logging must not depend on a broker being present.
"""
from __future__ import annotations

import json

import paho.mqtt.client as mqtt   # raises ImportError if absent; caller handles

from .telemetry import TelemetryState


class MqttPublisher:
    def __init__(self, host: str = "localhost", port: int = 1883,
                 topic: str = "drone/telemetry", qos: int = 0):
        self.topic = topic
        self.qos = qos
        self._client = mqtt.Client()
        # connect_async + loop_start so a missing broker does not block the
        # telemetry loop; publishes queue until the connection comes up.
        self._client.connect_async(host, port, keepalive=30)
        self._client.loop_start()

    def publish(self, state: TelemetryState) -> None:
        payload = json.dumps(state.as_dict())
        # retain=True so a subscriber that connects late still gets the last
        # known state immediately, which is what a dashboard wants.
        self._client.publish(self.topic, payload, qos=self.qos, retain=True)

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()
