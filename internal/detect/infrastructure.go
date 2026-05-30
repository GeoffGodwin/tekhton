package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// InfrastructureDetector ports lib/detect_infrastructure.sh —
// Terraform, Pulumi, CDK, CloudFormation/SAM, Ansible. Read-only:
// never reads .tfstate files (may contain secrets).
type InfrastructureDetector struct{}

// Name returns the canonical detector name.
func (InfrastructureDetector) Name() string { return "infrastructure" }

// Run executes IaC detection.
func (InfrastructureDetector) Run(_ context.Context, in *Input) (*Result, error) {
	r := &Result{Detector: "infrastructure"}
	for _, item := range detectInfrastructure(in.ProjectDir) {
		r.Findings = append(r.Findings, map[string]string{
			"tool":       item.Tool,
			"path":       item.Path,
			"provider":   item.Provider,
			"confidence": item.Confidence,
		})
	}
	return r, nil
}

func detectInfrastructure(dir string) []InfraItem {
	var out []InfraItem
	out = append(out, detectTerraform(dir)...)
	out = append(out, detectPulumi(dir)...)
	out = append(out, detectCDK(dir)...)
	out = append(out, detectCloudFormation(dir)...)
	out = append(out, detectAnsible(dir)...)
	return out
}

func detectTerraform(dir string) []InfraItem {
	var tfFiles []string
	for _, p := range listFilesDepth(dir, 3) {
		if !strings.HasSuffix(p, ".tf") {
			continue
		}
		if strings.Contains(p, "/.terraform/") || strings.HasPrefix(p, ".terraform/") {
			continue
		}
		if strings.Contains(p, "/node_modules/") || strings.HasPrefix(p, "node_modules/") {
			continue
		}
		tfFiles = append(tfFiles, p)
		if len(tfFiles) >= 20 {
			break
		}
	}
	var out []InfraItem
	if len(tfFiles) > 0 {
		dirs := map[string]struct{}{}
		for _, f := range tfFiles {
			d := filepath.Dir(f)
			if d == "." || d == "" {
				dirs["."] = struct{}{}
			} else {
				dirs[d] = struct{}{}
			}
		}
		sortedDirs := make([]string, 0, len(dirs))
		for d := range dirs {
			sortedDirs = append(sortedDirs, d)
		}
		sort.Strings(sortedDirs)
		if len(sortedDirs) > 5 {
			sortedDirs = sortedDirs[:5]
		}
		provider := "unknown"
		first := sortedDirs[0]
		checkPath := dir
		if first != "." {
			checkPath = filepath.Join(dir, first)
		}
		body := concatTFContents(checkPath)
		switch {
		case regexMatchAny(body, `provider "aws"|source.*hashicorp/aws`):
			provider = "aws"
		case regexMatchAny(body, `provider "google"|source.*hashicorp/google`):
			provider = "gcp"
		case regexMatchAny(body, `provider "azurerm"|source.*hashicorp/azurerm`):
			provider = "azure"
		}
		for _, d := range sortedDirs {
			out = append(out, InfraItem{Tool: "terraform", Path: d, Provider: provider, Confidence: "high"})
		}
	}
	if len(tfFiles) == 0 && dirExists(filepath.Join(dir, "terraform")) {
		out = append(out, InfraItem{Tool: "terraform", Path: "terraform", Provider: "unknown", Confidence: "medium"})
	}
	if len(tfFiles) == 0 && fileExists(filepath.Join(dir, ".terraform.lock.hcl")) {
		out = append(out, InfraItem{Tool: "terraform", Path: ".", Provider: "unknown", Confidence: "medium"})
	}
	return out
}

func concatTFContents(dir string) string {
	matches := globMany(dir, "*.tf")
	var b strings.Builder
	for _, m := range matches {
		b.WriteString(readFile(m))
		b.WriteByte('\n')
	}
	return b.String()
}

func detectPulumi(dir string) []InfraItem {
	if !fileExists(filepath.Join(dir, "Pulumi.yaml")) {
		return nil
	}
	provider := "unknown"
	for _, sf := range globMany(dir, "Pulumi.*.yaml") {
		body := readFile(sf)
		switch {
		case regexMatchAny(body, `aws:`):
			provider = "aws"
		case regexMatchAny(body, `gcp:`):
			provider = "gcp"
		case regexMatchAny(body, `azure:`):
			provider = "azure"
		}
		if provider != "unknown" {
			break
		}
	}
	return []InfraItem{{Tool: "pulumi", Path: ".", Provider: provider, Confidence: "high"}}
}

func detectCDK(dir string) []InfraItem {
	if fileExists(filepath.Join(dir, "cdk.json")) {
		return []InfraItem{{Tool: "aws-cdk", Path: ".", Provider: "aws", Confidence: "high"}}
	}
	if dirExists(filepath.Join(dir, "cdk.out")) {
		return []InfraItem{{Tool: "aws-cdk", Path: ".", Provider: "aws", Confidence: "medium"}}
	}
	return nil
}

func detectCloudFormation(dir string) []InfraItem {
	rxFormatVersion := regexp.MustCompile(`AWSTemplateFormatVersion`)
	for _, c := range []string{"template.yaml", "template.json", "cloudformation.yaml", "cloudformation.json"} {
		p := filepath.Join(dir, c)
		if !fileExists(p) {
			continue
		}
		if rxFormatVersion.MatchString(readFile(p)) {
			return []InfraItem{{Tool: "cloudformation", Path: c, Provider: "aws", Confidence: "high"}}
		}
	}
	tpl := filepath.Join(dir, "template.yaml")
	if fileExists(tpl) && strings.Contains(readFile(tpl), "AWS::Serverless") {
		return []InfraItem{{Tool: "sam", Path: "template.yaml", Provider: "aws", Confidence: "high"}}
	}
	return nil
}

func detectAnsible(dir string) []InfraItem {
	if fileExists(filepath.Join(dir, "ansible.cfg")) {
		return []InfraItem{{Tool: "ansible", Path: ".", Provider: "unknown", Confidence: "high"}}
	}
	if dirExists(filepath.Join(dir, "playbooks")) || dirExists(filepath.Join(dir, "roles")) {
		return []InfraItem{{Tool: "ansible", Path: ".", Provider: "unknown", Confidence: "medium"}}
	}
	if dirExists(filepath.Join(dir, "inventory")) {
		if fileExists(filepath.Join(dir, "inventory", "hosts")) || fileExists(filepath.Join(dir, "inventory", "hosts.yml")) {
			return []InfraItem{{Tool: "ansible", Path: ".", Provider: "unknown", Confidence: "medium"}}
		}
	}
	return nil
}
