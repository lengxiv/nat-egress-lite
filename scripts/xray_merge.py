#!/usr/bin/env python3
"""Safely merge the nat-egress SOCKS route into one Xray root JSON config.

The program deliberately knows nothing about systemd.  It only reads JSON and
writes a replacement JSON file, which lets setup-jp.sh validate a sibling
candidate before atomically installing it.
"""
from __future__ import annotations

import copy
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

NAT_TAG = "nat-egress"
BLOCK_TAG = "nat-egress-block"
SAFE_PROTOCOLS = {"api", "dokodemo-door"}


class MergeError(ValueError):
    """A configuration cannot be safely changed automatically."""


class NeedConfig(MergeError):
    """Human selection is required; the caller should return status 20."""


def env_required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise MergeError(f"缺少环境变量 {name}")
    return value


def merge_parameters() -> tuple[int, str, str, list[str]]:
    remote_text = env_required("NE_REMOTE_PORT")
    try:
        remote_port = int(remote_text, 10)
    except ValueError as exc:
        raise MergeError("NE_REMOTE_PORT 不是整数") from exc
    if not 1024 <= remote_port <= 65535:
        raise MergeError("NE_REMOTE_PORT 必须在 1024..65535")

    socks_user = env_required("NE_SOCKS_USER")
    socks_pass = env_required("NE_SOCKS_PASS")
    if not re.fullmatch(r"[0-9A-Fa-f]{48}", socks_pass):
        raise MergeError("NE_SOCKS_PASS 必须为 48 位十六进制随机串")

    tag_text = env_required("NE_INBOUND_TAG")
    if tag_text == "auto":
        return remote_port, socks_user, socks_pass, ["auto"]
    tags = [item.strip() for item in tag_text.split(",") if item.strip()]
    if not tags or len(tags) != len(set(tags)):
        raise MergeError("NE_INBOUND_TAG 不能为空或包含重复 tag")
    return remote_port, socks_user, socks_pass, tags


def load_root(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise MergeError(f"无法读取 Xray 配置: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MergeError(f"Xray 配置不是有效 JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise MergeError("Xray 根配置必须是 JSON 对象")
    return raw


def inbound_options(root: dict[str, Any]) -> list[str]:
    inbounds = root.get("inbounds", [])
    if not isinstance(inbounds, list):
        raise MergeError("inbounds 必须是数组")
    options: list[str] = []
    for inbound in inbounds:
        if not isinstance(inbound, dict):
            continue
        protocol = inbound.get("protocol")
        tag = inbound.get("tag")
        if protocol in SAFE_PROTOCOLS or not isinstance(tag, str) or not tag:
            continue
        options.append(tag)
    # Repeated tags are itself unsafe, but report one option only once to the
    # operator rather than producing an ambiguous answer.
    return list(dict.fromkeys(options))


def select_inbound_tags(root: dict[str, Any], requested: list[str]) -> list[str]:
    options = inbound_options(root)
    if requested == ["auto"]:
        if len(options) != 1:
            raise NeedConfig(
                "自动选择需要唯一的可代理入站；请设置 NE_INBOUND_TAG"
            )
        return options
    missing = [tag for tag in requested if tag not in options]
    if missing:
        raise MergeError("指定的 NE_INBOUND_TAG 不存在或属于 api/dokodemo-door")
    return requested


def project_socks_shape(outbound: Any) -> bool:
    """Recognize our tag without accepting an unrelated user-owned outbound."""
    if not isinstance(outbound, dict):
        return False
    if outbound.get("tag") != NAT_TAG or outbound.get("protocol") != "socks":
        return False
    settings = outbound.get("settings")
    if set(outbound) != {"tag", "protocol", "settings", "mux"}:
        return False
    if not isinstance(settings, dict) or set(settings) != {"servers"}:
        return False
    servers = settings.get("servers")
    if not isinstance(servers, list) or len(servers) != 1 or not isinstance(servers[0], dict):
        return False
    server = servers[0]
    if set(server) != {"address", "port", "users"} or server.get("address") != "127.0.0.1":
        return False
    users = server.get("users")
    if (
        not isinstance(server.get("port"), int)
        or not 1024 <= server["port"] <= 65535
        or not isinstance(users, list)
        or len(users) != 1
    ):
        return False
    if not isinstance(users[0], dict) or set(users[0]) != {"user", "pass"}:
        return False
    if (
        not isinstance(users[0].get("user"), str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", users[0]["user"])
        or not isinstance(users[0].get("pass"), str)
        or not re.fullmatch(r"[0-9A-Fa-f]{48}", users[0]["pass"])
    ):
        return False
    mux = outbound.get("mux")
    return isinstance(mux, dict) and mux == {"enabled": False}


def project_block_shape(outbound: Any) -> bool:
    return (
        isinstance(outbound, dict)
        and set(outbound) == {"tag", "protocol", "settings"}
        and outbound.get("tag") == BLOCK_TAG
        and outbound.get("protocol") == "blackhole"
        and outbound.get("settings") == {}
    )


def desired_outbounds(port: int, user: str, password: str) -> tuple[dict[str, Any], dict[str, Any]]:
    socks = {
        "tag": NAT_TAG,
        "protocol": "socks",
        "settings": {
            "servers": [
                {
                    "address": "127.0.0.1",
                    "port": port,
                    "users": [{"user": user, "pass": password}],
                }
            ]
        },
        "mux": {"enabled": False},
    }
    block = {"tag": BLOCK_TAG, "protocol": "blackhole", "settings": {}}
    return socks, block


def replace_project_outbounds(root: dict[str, Any], port: int, user: str, password: str) -> None:
    outbounds = root.get("outbounds", [])
    if not isinstance(outbounds, list):
        raise MergeError("outbounds 必须是数组")
    desired_socks, desired_block = desired_outbounds(port, user, password)
    found: dict[str, int] = {}
    for index, outbound in enumerate(outbounds):
        if not isinstance(outbound, dict):
            continue
        tag = outbound.get("tag")
        if tag in (NAT_TAG, BLOCK_TAG):
            if tag in found:
                raise MergeError(f"发现重复 outbound tag: {tag}")
            found[tag] = index
            valid = project_socks_shape(outbound) if tag == NAT_TAG else project_block_shape(outbound)
            if not valid:
                raise MergeError(f"已有 {tag} 不是 nat-egress 项目形态，拒绝覆盖")

    # Existing outbound positions are retained.  This is important when the
    # first outbound is a deliberate Xray default route.
    if NAT_TAG in found:
        outbounds[found[NAT_TAG]] = desired_socks
    else:
        outbounds.append(desired_socks)
    if BLOCK_TAG in found:
        outbounds[found[BLOCK_TAG]] = desired_block
    else:
        outbounds.append(desired_block)
    root["outbounds"] = outbounds


def is_project_rule(rule: Any) -> bool:
    if not isinstance(rule, dict) or rule.get("type") != "field":
        return False
    network = rule.get("network")
    outbound = rule.get("outboundTag")
    return (network == "udp" and outbound == BLOCK_TAG) or (
        network == "tcp" and outbound == NAT_TAG
    )


def is_safety_block(rule: Any) -> bool:
    """Keep pre-existing security blocks before the new selected route.

    Xray routing is first-match.  A leading blackhole/private-network rule
    must therefore remain in front of our TCP catch-all.  We intentionally
    only preserve a *leading* safety prefix, so unrelated later rules do not
    get reordered.
    """
    if not isinstance(rule, dict):
        return False
    outbound = rule.get("outboundTag")
    if outbound in {"blackhole", "block", "blocked"}:
        return True
    values: list[str] = []
    for key in ("ip", "domain"):
        value = rule.get(key)
        if isinstance(value, str):
            values.append(value)
        elif isinstance(value, list):
            values.extend(item for item in value if isinstance(item, str))
    return any(item.lower() in {"geoip:private", "private"} for item in values)


def replace_project_rules(root: dict[str, Any], tags: list[str]) -> None:
    routing = root.get("routing")
    if routing is None:
        routing = {}
        root["routing"] = routing
    if not isinstance(routing, dict):
        raise MergeError("routing 必须是对象")
    rules = routing.get("rules", [])
    if not isinstance(rules, list):
        raise MergeError("routing.rules 必须是数组")

    # Remove only unambiguously project-owned rules.  Rules that merely happen
    # to use a similar inbound tag or a generic blackhole are not touched.
    retained = [rule for rule in rules if not is_project_rule(rule)]
    safety_count = 0
    for rule in retained:
        if is_safety_block(rule):
            safety_count += 1
        else:
            break
    project_rules = [
        {
            "type": "field",
            "inboundTag": tags,
            "network": "udp",
            "outboundTag": BLOCK_TAG,
        },
        {
            "type": "field",
            "inboundTag": tags,
            "network": "tcp",
            "outboundTag": NAT_TAG,
        },
    ]
    routing["rules"] = retained[:safety_count] + project_rules + retained[safety_count:]


def merge(root: dict[str, Any]) -> dict[str, Any]:
    port, user, password, requested = merge_parameters()
    tags = select_inbound_tags(root, requested)
    result = copy.deepcopy(root)
    replace_project_outbounds(result, port, user, password)
    replace_project_rules(result, tags)
    return result


def write_json(path: Path, content: dict[str, Any]) -> None:
    path.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def make_fragment() -> dict[str, Any]:
    port, user, password, requested = merge_parameters()
    if requested == ["auto"]:
        raise NeedConfig("fragment 模式无法自动发现入站；请设置 NE_INBOUND_TAG")
    socks, block = desired_outbounds(port, user, password)
    return {
        "outbounds": [socks, block],
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "inboundTag": requested,
                    "network": "udp",
                    "outboundTag": BLOCK_TAG,
                },
                {
                    "type": "field",
                    "inboundTag": requested,
                    "network": "tcp",
                    "outboundTag": NAT_TAG,
                },
            ]
        },
    }


def print_need_config(root: dict[str, Any], reason: str) -> int:
    options = inbound_options(root)
    # These are a machine-readable, deliberately secret-free contract with the
    # shell helper.  stdout must contain no prose on this path.
    print(f"NE_NEED_CONFIG={reason}")
    print("NE_INBOUND_OPTIONS=" + ",".join(options))
    return 20


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[1] == "--inspect":
            root = load_root(Path(argv[2]))
            _, _, _, requested = merge_parameters()
            try:
                select_inbound_tags(root, requested)
            except NeedConfig as exc:
                return print_need_config(root, str(exc))
            return 0
        if len(argv) == 3 and argv[1] == "--fragment":
            try:
                write_json(Path(argv[2]), make_fragment())
            except NeedConfig as exc:
                # There is no root config from which to list choices.
                print(f"NE_NEED_CONFIG={exc}")
                print("NE_INBOUND_OPTIONS=")
                return 20
            return 0
        if len(argv) != 3:
            raise MergeError("用法: xray_merge.py INPUT.json OUTPUT.json | --inspect INPUT.json | --fragment OUTPUT.json")
        root = load_root(Path(argv[1]))
        try:
            result = merge(root)
        except NeedConfig as exc:
            return print_need_config(root, str(exc))
        write_json(Path(argv[2]), result)
        return 0
    except MergeError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"错误：文件操作失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
