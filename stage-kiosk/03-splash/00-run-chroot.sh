#!/bin/bash -e

# -R sets it as the default theme and rebuilds the initramfs so it's actually
# picked up on boot.
plymouth-set-default-theme -R uvatransit
