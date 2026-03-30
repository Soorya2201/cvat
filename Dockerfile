FROM sooryacvatreg.azurecr.io/cvat-ui:latest

# Switch to root to modify the Nginx config
USER root

# Change the default Nginx port from 80 to 8081
RUN sed -i 's/listen       80;/listen       8081;/g' /etc/nginx/conf.d/default.conf || \
    printf 'server {\n listen 8081;\n root /usr/share/nginx/html;\n location / { try_files $uri $uri/ /index.html; }\n}\n' > /etc/nginx/conf.d/default.conf

# Switch back to the non-root user for security and ACI compatibility
USER nginx

# Expose the new port
EXPOSE 8081
