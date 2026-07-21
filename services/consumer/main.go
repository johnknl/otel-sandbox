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
	"os"

	"github.com/segmentio/kafka-go"
)

const (
	topic    = "a-topic"
	groupID  = "consumer-group"
	maxBytes = 10 << 20 // 10MB
)

var logger *slog.Logger

func init() {
	logger = slog.New(slog.NewJSONHandler(log.Writer(), &slog.HandlerOptions{
		Level: slog.LevelDebug,
	}))
}

func main() {
	ctx := context.Background()

	r := kafka.NewReader(kafka.ReaderConfig{
		Brokers:  []string{"kafka-otel-sandbox-kafka-bootstrap:9092"},
		Topic:    topic,
		GroupID:  groupID,
		MaxBytes: maxBytes,
	})

	defer func() {
		if err := r.Close(); err != nil {
			logger.ErrorContext(ctx, "failed to close reader", "err", err)
		}
	}()

	logger.DebugContext(ctx, "starting consumer", "topic", topic, "groupID", groupID)
	for {
		m, err := r.FetchMessage(ctx)
		if err != nil {
			logger.ErrorContext(ctx, "failed to fetch message", "err", err)
			os.Exit(1)
		}

		var traceParent string

		for _, h := range m.Headers {
			if h.Key == "traceparent" {
				traceParent = string(h.Value)
				break
			}
		}

		logger.DebugContext(
			ctx,
			string(m.Value),
			slog.String("topic", m.Topic),
			slog.Int("partition", m.Partition),
			slog.Int64("offset", m.Offset),
			// this is not the proper otel way to propagate the trace context
			// it's just for me to easily see the traceparent of the sender
			// to debug the tracing itself, as apposed to the thing it is tracing
			// without having to inspect the kafka message manually
			slog.String("x-traceparent", traceParent),
		)

		if err := r.CommitMessages(ctx, m); err != nil {
			logger.ErrorContext(ctx, "failed to commit message", "err", err)
			os.Exit(1)
		}
	}
}
