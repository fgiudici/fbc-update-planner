/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package plcccheck

import (
	"bytes"
	"encoding/json"
	"slices"

	"github.com/release-engineering/fbc-update-planner/pkg/fbc"
)

// lifecycleMatches compares all generated and shipped records for a package.
// Record and unordered list order is ignored, but multiplicity is preserved.
// Catalog records are intentionally not decoded into fbc.Package: doing so
// would discard unknown fields and conflate omitted, null, and empty values.
func lifecycleMatches(generated []*fbc.Package, shipped []json.RawMessage) (bool, error) {
	expected, err := canonicalLifecycles(generated)
	if err != nil {
		return false, err
	}
	actual, err := canonicalLifecycles(shipped)
	if err != nil {
		return false, err
	}
	return slices.Equal(expected, actual), nil
}

func canonicalLifecycles(input any) ([]string, error) {
	data, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	var records []map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&records); err != nil {
		return nil, err
	}
	result := make([]string, 0, len(records))
	for _, record := range records {
		versions, _ := record["versions"].([]any)
		for _, value := range versions {
			version, _ := value.(map[string]any)
			platforms, _ := version["platformCompatibility"].([]any)
			for _, value := range platforms {
				platform, _ := value.(map[string]any)
				if err := sortJSONField(platform, "versions"); err != nil {
					return nil, err
				}
			}
			if err := sortJSONField(version, "platformCompatibility"); err != nil {
				return nil, err
			}
		}
		if err := sortJSONField(record, "versions"); err != nil {
			return nil, err
		}
		encoded, err := json.Marshal(record)
		if err != nil {
			return nil, err
		}
		result = append(result, string(encoded))
	}
	slices.Sort(result)
	return result, nil
}

// sortJSONField only sorts arrays at known unordered schema fields. Malformed
// field types, absent fields, and nulls are preserved for comparison. Phases
// and arrays inside unknown fields keep their original order.
func sortJSONField(object map[string]any, field string) error {
	values, ok := object[field].([]any)
	if !ok {
		return nil
	}
	encoded := make([]json.RawMessage, len(values))
	for i, value := range values {
		data, err := json.Marshal(value)
		if err != nil {
			return err
		}
		encoded[i] = data
	}
	slices.SortFunc(encoded, func(a, b json.RawMessage) int { return bytes.Compare(a, b) })
	object[field] = encoded
	return nil
}
