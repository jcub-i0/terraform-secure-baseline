FROM public.ecr.aws/docker/library/alpine:3.22

RUN apk add --no-cache busybox-extras \
  && mkdir -p /www \
  && printf 'ok\n' > /www/index.html

CMD ["busybox-extras", "httpd", "-f", "-p", "8080", "-h", "/www"]