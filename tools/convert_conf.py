#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Shadowrocket .conf → sing-box JSON 转换器

支持 [Rule] 段:
  DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / IP-CIDR6 /
  DST-PORT / SRC-PORT / PROCESS-NAME / FINAL
策略映射:
  PROXY  → 代理出站 (默认 yg-node)
  DIRECT → direct 出站
  REJECT → block 出站（sing-box 的 block 即拒绝）

[General] 段:
  dns-server 提取进 dns.servers（直连解析）

[Host] 段忽略（sing-box 无等价简单映射）

用法:
  python convert_conf.py 输入.conf -s 服务器 -p 端口 -u 用户 -w 密码 [-o 输出.json]
"""
import argparse
import json
import re
import sys

RULE_MAP = {
    "DOMAIN": "domain",
    "DOMAIN-SUFFIX": "domain_suffix",
    "DOMAIN-KEYWORD": "domain_keyword",
    "IP-CIDR": "ip_cidr",
    "IP6-CIDR": "ip_cidr",
    "IP-CIDR6": "ip_cidr",
    "DST-PORT": "port",
    "SRC-PORT": "source_port",
    "PROCESS-NAME": "process_name",
}
PORT_KEYS = {"port", "source_port"}


def parse_conf(text):
    rules = []          # 保序的规则列表
    final = None        # FINAL 策略
    dns_servers = []
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        m = re.match(r"^\[(.+?)\]", line)
        if m:
            section = m.group(1).strip().lower()
            continue
        if section == "general":
            mm = re.match(r"^dns-server\s*=\s*(.+)$", line, re.I)
            if mm:
                dns_servers.extend(x.strip() for x in mm.group(1).split(",") if x.strip())
            continue
        if section != "rule":
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        kind = parts[0].upper()
        policy = parts[-1].upper()
        if kind == "FINAL":
            final = policy
            continue
        key = RULE_MAP.get(kind)
        if not key or policy not in ("PROXY", "DIRECT", "REJECT"):
            continue
        value = parts[1]
        if not value:
            continue
        if key in PORT_KEYS:
            # 支持 10012 或 1000-2000 端口段
            if "-" in value:
                a, b = value.split("-", 1)
                value = [int(a), int(b)]
            else:
                value = int(value)
        rules.append((key, value, policy))
    return rules, final, dns_servers


def build_config(text, server, port, username, password, proxy_tag="yg-node"):
    rules, final, dns_servers = parse_conf(text)

    outbounds = [
        {"type": "socks", "tag": proxy_tag,
         "server": server, "server_port": int(port), "version": "5",
         "username": username or "", "password": password or ""},
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ]

    route_rules = []
    for key, value, policy in rules:
        out = {"PROXY": proxy_tag, "DIRECT": "direct", "REJECT": "block"}[policy]
        route_rules.append({key: value if isinstance(value, list) else [value],
                            "outbound": out})

    route = {"rules": route_rules,
             "final": {"PROXY": proxy_tag, "DIRECT": "direct", "REJECT": "block"}.get(final, proxy_tag)}

    cfg = {"outbounds": outbounds, "route": route}
    if dns_servers:
        # 新版 DNS 服务器格式（sing-box 1.12+ 要求，兼容 1.13/1.14）
        # 注意：新式 DNS 服务器不能设 detour=direct（会报
        # "detour to an empty direct outbound makes no sense"）；
        # 默认行为本身就是空 direct 拨号，无需指定。
        cfg["dns"] = {"servers": [
            {"type": "udp", "tag": f"dns-{i+1}", "server": d}
            for i, d in enumerate(dns_servers)
        ]}
    return cfg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("conf")
    ap.add_argument("-s", "--server", required=True)
    ap.add_argument("-p", "--port", required=True)
    ap.add_argument("-u", "--username", default="")
    ap.add_argument("-w", "--password", default="")
    ap.add_argument("-o", "--output", default="")
    args = ap.parse_args()

    with open(args.conf, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()

    cfg = build_config(text, args.server, args.port, args.username, args.password)
    out = json.dumps(cfg, ensure_ascii=False, indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"已写入 {args.output}")
    else:
        print(out)


if __name__ == "__main__":
    main()
