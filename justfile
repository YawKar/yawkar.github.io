[default]
[private]
default:
    @just --list --unsorted

# format everything
[group("Code Style")]
format check="":
    # nix
    find . -type f -name "*.nix" -exec nixfmt -sv {{ if check != "" { "-c" } else { "" } }} {} + 
    # just
    just --fmt {{ if check != "" { "--check" } else { "" } }}
[group("Code Style")]
format-check: (format "check")

# lint everything
[group("Code Style")]
lint fix="":
    # nix
    statix {{ if fix != "" { "fix" } else { "check" } }}
    # lychee: dead links
    lychee .
[group("Code Style")]
lint-fix: (lint "fix")

[private]
pre-commit-hook: format-check lint
