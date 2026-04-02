#!/bin/sh
# Replace BACKEND_URL placeholder with actual backend URL at runtime
sed -i "s|BACKEND_URL_PLACEHOLDER|http://${BACKEND_HOST:-localhost}:8080|g" /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
