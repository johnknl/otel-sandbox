// MIT License
//
// Copyright (C) 2025 John Kleijn
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE

package main

import (
	"context"
	"log"
	"log/slog"
	"time"

	pb "github.com/johnknl/otel-sandbox/pkg/protogen/backend/v1"
	"go.opentelemetry.io/otel"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var logger *slog.Logger

func init() {
	logger = slog.New(slog.NewJSONHandler(log.Writer(), &slog.HandlerOptions{
		Level: slog.LevelDebug,
	}))
}

func main() {
	conn, err := grpc.NewClient(
		"backend:50051",
		grpc.WithTransportCredentials(
			insecure.NewCredentials(),
		),
	)
	if err != nil {
		log.Fatal(err)
	}

	client := pb.NewBackendServiceClient(conn)
	ticker := time.NewTicker(5 * time.Second)

	for range ticker.C {
		ctx := context.Background()

		tracer := otel.Tracer("frontend")

		ctx, span := tracer.Start(ctx, "service.call_backend")

		resp, err := client.GetMessage(ctx, &pb.GetMessageRequest{
			Name: "otel",
		})

		span.End()

		if err != nil {
			logger.ErrorContext(ctx, "failed to call backend", "error", err)
		} else {
			logger.DebugContext(ctx, "received response from backend", "message", resp.Message)
		}
	}
}
