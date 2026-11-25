#!/bin/bash
# Configure unattended security-only patching via dnf-automatic.
# Schedule is baked in from SECURITY_PATCH_SCHEDULE (systemd OnCalendar expression) but can be
# changed later on a running instance without reinstalling anything — see the override file
# written below.
set -e

if [ -z "${SECURITY_PATCH_SCHEDULE:-}" ]; then
  echo "WARNING: SECURITY_PATCH_SCHEDULE is not set, falling back to weekly (Sun *-*-* 09:00:00 UTC)" >&2
  SECURITY_PATCH_SCHEDULE="Sun *-*-* 09:00:00 UTC"
fi

dnf install -y dnf-automatic

# AL2023's dnf-automatic (currently 4.14.0) predates the upstream dnf 4.15.0 release that added
# the reboot/reboot_command config options -- they're silently ignored here, not a typo (see
# https://github.com/amazonlinux/amazon-linux-2023/issues/636). smart-restart is AWS's own
# supported replacement: it hooks dnf's post-transaction-actions plugin (runs after every dnf
# transaction, including dnf-automatic's) and writes /run/smart-restart/reboot-hint-marker when a
# reboot is actually warranted. The systemd drop-in below checks that marker and runs reboot.sh --
# the only trigger that actually works on this platform.
dnf install -y smart-restart

cat > /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
random_sleep = 0

[emitters]
emit_via = stdio

[base]
debuglevel = 1
# Never auto-patch the Kubernetes/container runtime stack managed by the AMI/cluster tooling.
exclude = kube* docker* container* runc*
EOF

mkdir -p /etc/systemd/system/dnf-automatic.service.d
cat > /etc/systemd/system/dnf-automatic.service.d/override.conf <<'EOF'
[Service]
ExecStartPost=-/bin/sh -c 'test -f /run/smart-restart/reboot-hint-marker && /var/lib/cloud-pipeline/system-updates/reboot.sh'
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
RandomizedDelaySec=30min
EOF

# By default AL2023 use repo version pinning, so the dnf will not get updates
echo "latest" > /etc/dnf/vars/releasever

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
