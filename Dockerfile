FROM golang:1.26 AS base

WORKDIR /src

COPY go.mod go.sum ./
COPY services/ ./services/
COPY pkg/ ./pkg/

RUN go mod download

FROM base AS build-frontend

RUN go build -o /frontend ./services/frontend/

FROM ubuntu:24.04 AS frontend

COPY --from=build-frontend /frontend /frontend

ENTRYPOINT ["/frontend"]

FROM base AS build-backend

RUN go build -o /backend ./services/backend/

FROM ubuntu:24.04 AS backend

COPY --from=build-backend /backend /backend

ENTRYPOINT ["/backend"]

FROM base AS build-consumer

RUN go build -o /consumer ./services/consumer/

FROM ubuntu:24.04 AS consumer

COPY --from=build-consumer /consumer /consumer

ENTRYPOINT ["/consumer"]
