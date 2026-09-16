#!/bin/bash
# install-nuc-all.sh ist veraltet und wurde durch install.sh ersetzt.
# Die Installation basiert jetzt auf den fertigen Docker-Hub-Images
# https://hub.docker.com/r/nuccess/nuclos-server - ein Installer-JAR und
# ein lokaler Image-Build sind nicht mehr erforderlich.
echo "⚠️  install-nuc-all.sh ist veraltet - starte ./install.sh ..."
exec "$(dirname "$0")/install.sh" "$@"
