FROM golang:1.10-alpine
LABEL maintainer "saboyutaka<yutaka.paradigm.shift@gmail.com>"

ENV APP_PATH=${GOPATH}/src/github.com/saboyutaka/isucon8q

RUN apk add --no-cache \
	git \
	openssh-client \
	gcc \
	libc-dev

RUN go get bitbucket.org/liamstask/goose/cmd/goose

WORKDIR ${APP_PATH}

ENTRYPOINT ["goose"]
