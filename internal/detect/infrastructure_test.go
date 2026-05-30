package detect

import (
	"context"
	"testing"
)

func TestInfrastructureDetector_Terraform(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"main.tf": `provider "aws" {}` + "\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatalf("expected terraform finding; got none")
	}
	if r.Findings[0]["tool"] != "terraform" || r.Findings[0]["provider"] != "aws" {
		t.Errorf("terraform: got %+v", r.Findings[0])
	}
}

func TestInfrastructureDetector_Pulumi(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Pulumi.yaml":     "name: p\n",
		"Pulumi.dev.yaml": "config:\n  aws:region: us-east-1\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 || r.Findings[0]["tool"] != "pulumi" {
		t.Fatalf("expected pulumi finding; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_None(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x"})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no infra; got %v", r.Findings)
	}
}
