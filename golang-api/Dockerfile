FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod download
RUN go build -o golang-api main.go

FROM alpine:latest
COPY --from=builder /app/golang-api /usr/local/bin/
CMD ["golang-api"]
