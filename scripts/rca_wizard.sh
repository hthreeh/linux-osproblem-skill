#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/vmcore/rca_wizard.sh" "$@"
