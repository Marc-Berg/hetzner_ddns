FROM alpine:latest
RUN apk add --no-cache curl && \
    curl -OL 'https://github.com/Marc-Berg/hetzner_ddns/releases/download/v1.1.0-ipv6-monitor/hetzner_ddns-1.1.0-alpinelinux.apk' && \
    apk add --no-interactive --allow-untrusted ./hetzner_ddns-1.1.0-alpinelinux.apk && \
    rm -f ./hetzner_ddns-1.1.0-alpinelinux.apk
ENTRYPOINT ["hetzner_ddns", "-V"]
