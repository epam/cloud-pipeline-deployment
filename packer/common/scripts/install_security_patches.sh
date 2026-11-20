#!/bin/bash
# Configure unattended security-only patching via dnf-automatic.
# Schedule is baked in from SECURITY_PATCH_SCHEDULE (systemd OnCalendar expression) but can be
# changed later on a running instance without reinstalling anything — see the override file
# written below.
set -e

if [ -z "${SECURITY_PATCH_SCHEDULE:-}" ]; then
  echo "WARNING: SECURITY_PATCH_SCHEDULE is not set, falling back to weekly (Sun *-*-* 03:00:00)" >&2
  SECURITY_PATCH_SCHEDULE="Sun *-*-* 03:00:00"
fi

dnf install -y dnf-automatic

cat > /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes

[emitters]
emit_via = stdio

[base]
debuglevel = 1
# Never auto-patch the Kubernetes/container runtime stack managed by the AMI/cluster tooling.
exclude = kube* docker* container* runc*
EOF

# Drop-in (rather than editing the vendored unit) so the schedule survives package updates and
# can be changed on a live instance: edit this file (or `systemctl edit dnf-automatic.timer`)
# and run `systemctl daemon-reload` — no rebuild/reinstall needed.
# OnCalendar= (empty) clears the vendor unit's default schedule before adding ours — OnCalendar
# is additive across drop-ins, so without the reset both schedules would be active at once.
mkdir -p /etc/systemd/system/dnf-automatic.timer.d
cat > /etc/systemd/system/dnf-automatic.timer.d/override.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=${SECURITY_PATCH_SCHEDULE}
Persistent=true
RandomizedDelaySec=0
EOF

systemctl daemon-reload
systemctl enable dnf-automatic.timer

# Verify the merged unit and resolved next-run time:
#   systemctl cat dnf-automatic.timer          # shows base unit + all drop-ins merged
#   systemctl list-timers dnf-automatic.timer  # shows the single resolved next-run time

# To change the schedule later on an already-running instance, without rebuilding the AMI:
#   edit the file directly / `systemctl edit dnf-automatic.timer`, or via sed:
#   sudo sed -i 's|OnCalendar=.*\*.*|OnCalendar=<new systemd OnCalendar expression>|' \
#     /etc/systemd/system/dnf-automatic.timer.d/override.conf
#   sudo systemctl daemon-reload
#   systemctl list-timers dnf-automatic.timer   # confirm the new next-run time
