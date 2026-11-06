FROM golang:1.26.4-alpine AS build
WORKDIR /src
COPY database/go.mod database/go.sum ./
RUN go mod download
COPY database/searchsync ./searchsync
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /searchsync ./searchsync
FROM alpine:3.23
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 searchsync && mkdir /state && chown searchsync /state
COPY --from=build /searchsync /usr/local/bin/searchsync
COPY database/pgsync/schema.json /etc/searchsync/schema.json
USER searchsync
ENV SEARCH_SCHEMA_FILE=/etc/searchsync/schema.json
ENTRYPOINT ["/usr/local/bin/searchsync"]
