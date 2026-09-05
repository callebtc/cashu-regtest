#!/bin/sh
set -eu
if [ ! -f /data/initialized ]; then
  captaind --config /etc/bark/captaind.toml create
  touch /data/initialized
fi
exec captaind --config /etc/bark/captaind.toml start
