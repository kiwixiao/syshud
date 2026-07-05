#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o syshud syshud.swift
echo "Built ./syshud"
