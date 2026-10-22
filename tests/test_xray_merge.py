#!/usr/bin/env python3
"""Unit tests for the pure JSON Xray merger (no Xray/systemd service needed)."""
from __future__ import annotations

import importlib.util
import os
import unittest
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

PROJECT = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT / "scripts" / "xray_merge.py"
SPEC = importlib.util.spec_from_file_location("xray_merge", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
xray_merge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(xray_merge)


@contextmanager
def merger_env(*, port: str = "19080", password: str = "a" * 48, tag: str = "client") -> Iterator[None]:
    values = {
        "NE_REMOTE_PORT": port,
        "NE_SOCKS_USER": "egress",
        "NE_SOCKS_PASS": password,
        "NE_INBOUND_TAG": tag,
    }
    old = {key: os.environ.get(key) for key in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for key, prior in old.items():
            if prior is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = prior


def base_config() -> dict[str, object]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {"tag": "api-in", "protocol": "api", "listen": "127.0.0.1"},
            {"tag": "dns-in", "protocol": "dokodemo-door", "port": 53},
            {"tag": "client", "protocol": "vless", "port": 443},
        ],
        "outbounds": [
            {"tag": "direct", "protocol": "freedom", "settings": {}},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "ip": ["geoip:private"],
                    "outboundTag": "blocked",
                },
                {
                    "type": "field",
                    "inboundTag": ["other-inbound"],
                    "outboundTag": "direct",
                },
            ],
        },
    }


class XrayMergeTests(unittest.TestCase):
    def test_preserves_original_inbounds_and_leading_safety_rule(self) -> None:
        source = base_config()
        original_inbounds = source["inbounds"]
        with merger_env():
            result = xray_merge.merge(source)

        self.assertEqual(result["inbounds"], original_inbounds)
        self.assertEqual(result["log"], {"loglevel": "warning"})
        rules = result["routing"]["rules"]
        self.assertEqual(rules[0]["ip"], ["geoip:private"])
        self.assertEqual(rules[1], {
            "type": "field",
            "inboundTag": ["client"],
            "network": "udp",
            "outboundTag": "nat-egress-block",
        })
        self.assertEqual(rules[2], {
            "type": "field",
            "inboundTag": ["client"],
            "network": "tcp",
            "outboundTag": "nat-egress",
        })
        self.assertEqual(rules[3]["inboundTag"], ["other-inbound"])
        self.assertEqual(result["outbounds"][0]["tag"], "direct")

    def test_repeated_merge_is_idempotent(self) -> None:
        with merger_env(port="22123", password="b" * 48):
            once = xray_merge.merge(base_config())
            twice = xray_merge.merge(once)
        self.assertEqual(twice, once)
        rules = twice["routing"]["rules"]
        self.assertEqual(sum(rule.get("outboundTag") == "nat-egress" for rule in rules), 1)
        self.assertEqual(sum(rule.get("outboundTag") == "nat-egress-block" for rule in rules), 1)

    def test_auto_rejects_multiple_eligible_inbounds(self) -> None:
        source = base_config()
        source["inbounds"].append({"tag": "second-client", "protocol": "trojan", "port": 8443})
        with merger_env(tag="auto"):
            with self.assertRaises(xray_merge.NeedConfig):
                xray_merge.merge(source)
        self.assertEqual(xray_merge.inbound_options(source), ["client", "second-client"])

    def test_port_and_password_are_transmitted_without_change(self) -> None:
        password = "0123456789abcdef" * 3
        with merger_env(port="45678", password=password):
            result = xray_merge.merge(base_config())
        socks = next(item for item in result["outbounds"] if item["tag"] == "nat-egress")
        server = socks["settings"]["servers"][0]
        self.assertEqual(server["address"], "127.0.0.1")
        self.assertEqual(server["port"], 45678)
        self.assertEqual(server["users"], [{"user": "egress", "pass": password}])
        self.assertEqual(socks["mux"], {"enabled": False})


if __name__ == "__main__":
    unittest.main()
