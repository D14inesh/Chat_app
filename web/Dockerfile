# Frontend — static files served by nginx.
#   docker build -t chat-frontend ./web
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx-app.conf /etc/nginx/snippets/app.conf
COPY docker-entrypoint.sh /docker-entrypoint.d/40-chat-config.sh
RUN chmod +x /docker-entrypoint.d/40-chat-config.sh

COPY public/ /usr/share/nginx/html/

# 80 = HTTP; 443 = HTTPS, only when certs are mounted at /etc/nginx/certs
EXPOSE 80 443
