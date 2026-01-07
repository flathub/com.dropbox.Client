#!/bin/bash
set -ex
for icon_size in 16 22 24 32 48 64 256
do
    install -D -m644 data/icons/hicolor/${icon_size}x${icon_size}/apps/dropbox.png /app/share/icons/hicolor/${icon_size}x${icon_size}/apps/com.dropbox.Client.png
done

VERSION=$(awk 'match($0, /^AC_INIT.*, (.*)\)$/, a) { print a[1] }' configure.ac)
python3 build_dropbox.py "$VERSION" /app/share/applications < dropbox.in > /app/bin/dropbox
chmod 755 /app/bin/dropbox
