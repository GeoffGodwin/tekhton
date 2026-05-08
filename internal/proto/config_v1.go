package proto

// ConfigProtoV1 is the in-memory proto tag for the resolved pipeline.conf
// envelope emitted by `tekhton config load --emit json`.
//
// pipeline.conf itself stays in its legacy KEY=VALUE shell-sourceable form
// on disk — operators hand-edit it. This envelope describes only the parsed
// shape that the JSON emit path produces, not the on-disk format.
const ConfigProtoV1 = "tekhton.config.v1"

// ConfigV1 is the JSON-shaped view emitted by `tekhton config load --emit json`
// and `tekhton config show`. The `EnvelopeVer` field is stamped with
// ConfigProtoV1 by the producer; consumers reject unknown majors.
type ConfigV1 struct {
	Path        string            `json:"path"`
	ProjectDir  string            `json:"project_dir,omitempty"`
	Values      map[string]string `json:"values"`
	KeysSet     []string          `json:"keys_set"`
	Warnings    []string          `json:"warnings,omitempty"`
	Errors      []string          `json:"errors,omitempty"`
	CIDetected  bool              `json:"ci_detected"`
	CIPlatform  string            `json:"ci_platform,omitempty"`
	EnvelopeVer string            `json:"envelope_ver"`
}
