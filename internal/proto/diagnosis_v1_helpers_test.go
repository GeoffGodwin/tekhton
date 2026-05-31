package proto

import "encoding/json"

// unmarshalDiagnosisV1 is the test-only inverse of DiagnosisV1.MarshalJSON.
// Kept in a sibling file so the production diagnosis_v1.go does not import
// "encoding/json" for an inverse it does not use.
func unmarshalDiagnosisV1(b []byte, out *DiagnosisV1) error {
	type alias DiagnosisV1
	var a alias
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*out = DiagnosisV1(a)
	return nil
}
