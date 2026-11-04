# M2B negative-path fixture: the server responds on / but /health is absent.
# Use only in disposable staging to trigger ALB health-check failure.
FROM docker.io/library/alpine:3.22

RUN apk add --no-cache busybox-extras \
  && mkdir -p /www \
  && printf 'ok\n' > /www/index.html

USER 65534:65534

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD busybox wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

CMD ["busybox-extras", "httpd", "-f", "-p", "8080", "-h", "/www"]