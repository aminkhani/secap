FROM nginx:alpine

RUN mkdir -p \
    /usr/share/nginx/html/linux \
    /usr/share/nginx/html/windows

COPY linux/ /usr/share/nginx/html/linux/
COPY install-client.sh /usr/share/nginx/html/install-client.sh
COPY windows/Assessorv4.64.0.zip /usr/share/nginx/html/windows/Assessorv4.64.0.zip

RUN chmod 644 \
        /usr/share/nginx/html/install-client.sh \
        /usr/share/nginx/html/windows/Assessorv4.64.0.zip && \
    find /usr/share/nginx/html/linux -type f -exec chmod 644 '{}' ';' && \
    find /usr/share/nginx/html/linux -type d -exec chmod 755 '{}' ';' && \
    printf '%s\n' \
        'server {' \
        '    listen 8080;' \
        '    server_name _;' \
        '    root /usr/share/nginx/html;' \
        '' \
        '    autoindex on;' \
        '    autoindex_exact_size off;' \
        '    autoindex_localtime on;' \
        '' \
        '    location / {' \
        '        try_files $uri $uri/ =404;' \
        '    }' \
        '}' \
        > /etc/nginx/conf.d/default.conf

EXPOSE 8080