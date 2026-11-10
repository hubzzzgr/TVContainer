#!/bin/bash
set -euo pipefail
swift scripts/generate_tv_icon.swift
xcodegen generate --spec project.yml
