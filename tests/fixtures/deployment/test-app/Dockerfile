FROM public.ecr.aws/docker/library/alpine:3.22

RUN apk add --no-cache busybox-extras

CMD ["busybox-extras", "httpd", "-f", "-p", "8080"]