#!/bin/bash
set -e
echo "Running init..."
./backend_entrypoint.sh init
echo "Starting server..."
exec ./backend_entrypoint.sh run server
