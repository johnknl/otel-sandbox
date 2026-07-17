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
	"net"

	pb "github.com/johnknl/otel-sandbox/pkg/protogen/backend/v1"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"

	"google.golang.org/grpc"
)

type server struct {
	pb.UnimplementedBackendServiceServer
}

func (s *server) GetMessage(ctx context.Context, req *pb.GetMessageRequest) (*pb.GetMessageResponse, error) {
	tracer := otel.Tracer("backend")

	_, span := tracer.Start(ctx, "service.generate_message")
	defer span.End()

	span.SetAttributes(
		attribute.String("customer.name", req.Name),
	)

	return &pb.GetMessageResponse{
		Message: "hello " + req.Name,
	}, nil
}

func main() {
	lis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", ":50051") // nolint: gosec // no worries fam
	if err != nil {
		log.Fatal(err)
	}

	s := grpc.NewServer()

	pb.RegisterBackendServiceServer(s, &server{})

	log.Println("backend listening on :50051")

	if err := s.Serve(lis); err != nil {
		log.Fatal(err)
	}
}
