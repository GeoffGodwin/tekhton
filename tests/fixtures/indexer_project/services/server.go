package services

import "fmt"

type Server struct {
	Addr string
}

func NewServer(addr string) *Server {
	return &Server{Addr: addr}
}

func (s *Server) Start() error {
	fmt.Printf("server starting on %s\n", s.Addr)
	return nil
}
