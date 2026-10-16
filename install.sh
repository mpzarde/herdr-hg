#!/usr/bin/env bash
# Install herdr-hg from a local checkout: link the plugin into herdr, then run setup.
#   ./install.sh          interactive (shows the config diff, asks first)
#   ./install.sh --yes    non-interactive
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
for t in herdr hg jq nc perl; do command -v "$t" >/dev/null || { echo "install.sh: '$t' not found on PATH" >&2; exit 1; }; done
herdr plugin link "$here" >/dev/null
echo "Linked $here into herdr."
exec "$here/bin/hgwt-setup" "$@"
