# Resume Bar · tasks.

set shell := ["bash", "-euo", "pipefail", "-c"]

import? 'tools/private/tasks.just'

default:
    @just --list

# Compile everything (debug)
build:
    swift build

# All tests, parallel (Swift Testing)
test:
    RB_LANGUAGE=de swift test --parallel

# Tests of one module, e.g. `just t RBIndex`
t module:
    RB_LANGUAGE=de swift test --filter {{module}}Tests

# Signed release bundle in build/ResumeBar.app (Developer ID, Hardened Runtime)
app:
    swift build -c release --product ResumeBar
    swift build -c release --product rb
    tools/build-app-bundle.sh "$(swift build -c release --show-bin-path)/ResumeBar" build

# Host end-to-end check for person and AI through login
rb-e2e:
    tools/rb-e2e.sh

# Build the bundle and start it
run: app
    open build/ResumeBar.app

# Generate texts (COPY.csv), tokens.css and app.css from the design sources
gen:
    mkdir -p .build/tools
    swiftc -O -o .build/tools/gen tools/gen.swift
    .build/tools/gen .
