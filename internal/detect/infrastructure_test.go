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

func TestInfrastructureDetector_CDK(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"cdk.json": `{"app":"npx ts-node --prefer-ts-exts bin/app.ts"}` + "\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "aws-cdk" {
			found = true
			if row["provider"] != "aws" {
				t.Errorf("cdk provider: got %q, want aws", row["provider"])
			}
			if row["confidence"] != "high" {
				t.Errorf("cdk confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected aws-cdk finding; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_CloudFormation(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"template.yaml": "AWSTemplateFormatVersion: '2010-09-09'\nResources: {}\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "cloudformation" {
			found = true
			if row["provider"] != "aws" {
				t.Errorf("cfn provider: got %q, want aws", row["provider"])
			}
		}
	}
	if !found {
		t.Fatalf("expected cloudformation finding; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_SAM(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"template.yaml": "Transform: AWS::Serverless-2016-10-31\nResources:\n  Fn:\n    Type: AWS::Serverless::Function\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "sam" {
			found = true
			if row["provider"] != "aws" {
				t.Errorf("sam provider: got %q, want aws", row["provider"])
			}
		}
	}
	if !found {
		t.Fatalf("expected sam finding; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_AnsibleCfg(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"ansible.cfg": "[defaults]\ninventory = inventory/\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "ansible" {
			found = true
			if row["confidence"] != "high" {
				t.Errorf("ansible (cfg) confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected ansible finding via ansible.cfg; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_AnsiblePlaybooks(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"playbooks/site.yml": "---\n- hosts: all\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "ansible" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected ansible finding via playbooks/ dir; got %v", r.Findings)
	}
}

func TestInfrastructureDetector_TerraformGCPProvider(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"main.tf": `provider "google" { project = "my-project" }` + "\n",
	})
	r, _ := InfrastructureDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected terraform finding")
	}
	if r.Findings[0]["provider"] != "gcp" {
		t.Errorf("terraform gcp provider: got %q, want gcp", r.Findings[0]["provider"])
	}
}
