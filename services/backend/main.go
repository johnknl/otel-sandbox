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
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net"
	"os"
	"os/signal"

	pb "github.com/johnknl/otel-sandbox/pkg/protogen/backend/v1"
	"github.com/segmentio/kafka-go"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"

	"google.golang.org/grpc"
)

var manualSpansEnabled = os.Getenv("OTEL_MANUAL_SPANS_ENABLED") == "true"

type server struct {
	pb.UnimplementedBackendServiceServer
	writer *kafka.Writer
	logger *slog.Logger
}

func newServer(logger *slog.Logger) *server {
	return &server{
		logger: logger,
		writer: kafka.NewWriter(kafka.WriterConfig{
			Brokers:   []string{"kafka-otel-sandbox-kafka-bootstrap:9092"},
			Topic:     "a-topic",
			BatchSize: 1, // toy go brrr
		}),
	}
}

func (s *server) Close() error {
	if s.writer != nil {
		if err := s.writer.Close(); err != nil {
			return fmt.Errorf("failed to close writer: %w", err)
		}
	}

	return nil
}

func (s *server) GetMessage(ctx context.Context, req *pb.GetMessageRequest) (*pb.GetMessageResponse, error) {
	tracer := otel.Tracer("backend")

	// Check: we do not use the created context but because the auto-instrumentation uses goroutine
	// mapping to propagate the span context, the below Kafka MAY still become a child span of the GetMessage span.
	_, span := tracer.Start(ctx, "service.generate_message")
	defer span.End()

	span.SetAttributes(
		attribute.String("customer.name", req.Name),
		attribute.String("customer.id", req.Id),
	)

	mkMsg := func() ([]byte, error) {
		var msg struct {
			Name string `json:"name"`
			Id   string `json:"id"`
		}

		msg.Name = req.Name
		msg.Id = req.Id

		return json.Marshal(msg)
	}

	msg, err := mkMsg()
	if err != nil {
		return nil, fmt.Errorf("failed to marshal message: %w", err)
	}

	s.logger.DebugContext(ctx, "sending message to kafka", "message", string(msg))

	if err = s.writer.WriteMessages(ctx, kafka.Message{Value: msg}); err != nil {
		return nil, fmt.Errorf("failed to write kafka message: %w", err)
	}

	return &pb.GetMessageResponse{
		Message: string(msg),
	}, nil
}

func LoggingInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		logger.DebugContext(ctx, "received request", "request", req)

		return handler(ctx, req)
	}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(log.Writer(), &slog.HandlerOptions{
		Level: slog.LevelDebug,
	}))

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	err := func() error {
		lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", ":50051") // nolint: gosec // no worries fam
		if err != nil {
			return fmt.Errorf("failed to listen: %w", err)
		}

		s := grpc.NewServer(grpc.UnaryInterceptor(LoggingInterceptor(logger)))

		pb.RegisterBackendServiceServer(s, newServer(logger))

		logger.InfoContext(ctx, "grpc backend listening on :50051")

		if err := s.Serve(lis); err != nil {
			return fmt.Errorf("failed to serve: %w", err)
		}

		return nil
	}()

	if err != nil {
		logger.ErrorContext(ctx, err.Error())
	}
}
