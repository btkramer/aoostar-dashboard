#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_DIR="/mnt/tank/apps/aoostar-dashboard"
UNIT_DIR="/etc/systemd/system"

cp "$DASHBOARD_DIR/scripts/aoostar-asterctl.service" "$UNIT_DIR/aoostar-asterctl.service"
cp "$DASHBOARD_DIR/scripts/aoostar-sensors.service" "$UNIT_DIR/aoostar-sensors.service"
cp "$DASHBOARD_DIR/scripts/aoostar-container-updates.service" "$UNIT_DIR/aoostar-container-updates.service"
cp "$DASHBOARD_DIR/scripts/aoostar-container-updates.timer" "$UNIT_DIR/aoostar-container-updates.timer"

systemctl daemon-reload
systemctl enable --now aoostar-asterctl.service
systemctl enable --now aoostar-sensors.service
systemctl enable --now aoostar-container-updates.timer
