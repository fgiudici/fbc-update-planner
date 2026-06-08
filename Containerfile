FROM docker.io/library/golang:1.25-bookworm AS builder

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/
RUN CGO_ENABLED=0 go build -trimpath -o plcc2fbc ./cmd/plcc2fbc

RUN curl -sLo /tmp/2022-IT-Root-CA.pem https://certs.corp.redhat.com/certs/2022-IT-Root-CA.pem \
    && cat /tmp/2022-IT-Root-CA.pem >> /etc/ssl/certs/ca-certificates.crt

FROM registry.access.redhat.com/ubi10/ubi-micro:latest

COPY --from=builder /build/plcc2fbc /usr/local/bin/plcc2fbc
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt

USER 65534

ENTRYPOINT ["/usr/local/bin/plcc2fbc"]
