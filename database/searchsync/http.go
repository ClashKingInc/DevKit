package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

func validIndex(v string) bool {
	if len(v) < 1 || len(v) > 200 {
		return false
	}
	for _, r := range v {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}
func (s *service) request(ctx context.Context, method, path string, body []byte) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, method, s.endpoint+path, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if s.key != "" {
		req.Header.Set("Authorization", "ApiKey "+s.key)
	} else if s.user != "" {
		req.SetBasicAuth(s.user, s.password)
	}
	res, err := s.http.Do(req)
	if err != nil {
		return nil, 0, errors.New("Elasticsearch request failed")
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	if err != nil {
		return nil, res.StatusCode, err
	}
	return data, res.StatusCode, nil
}
func (s *service) bulk(ctx context.Context, e entity, items []item) error {
	var body bytes.Buffer
	enc := json.NewEncoder(&body)
	for _, v := range items {
		op := "index"
		if len(v.Document) == 0 || string(v.Document) == "null" {
			op = "delete"
		}
		if err := enc.Encode(map[string]any{op: map[string]any{"_index": e.index, "_id": v.Tag, "version": v.Generation, "version_type": "external_gte"}}); err != nil {
			return err
		}
		if op == "index" {
			body.Write(v.Document)
			body.WriteByte('\n')
		}
	}
	data, status, err := s.request(ctx, "POST", "/_bulk", body.Bytes())
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("bulk HTTP %d; queue retained", status)
	}
	var response struct {
		Items []map[string]struct {
			Status int `json:"status"`
			Error  *struct {
				Type string `json:"type"`
			} `json:"error"`
		} `json:"items"`
	}
	if err = json.Unmarshal(data, &response); err != nil {
		return err
	}
	if len(response.Items) != len(items) {
		return errors.New("bulk result length mismatch; queue retained")
	}
	for _, r := range response.Items {
		if len(r) != 1 {
			return errors.New("invalid bulk item")
		}
		for op, v := range r {
			if v.Status >= 200 && v.Status < 300 {
				continue
			}
			if op == "delete" && v.Status == 404 && v.Error == nil {
				continue
			}
			if v.Status == 409 && v.Error != nil && v.Error.Type == "version_conflict_engine_exception" {
				continue
			}
			return fmt.Errorf("bulk item HTTP %d; queue retained", v.Status)
		}
	}
	return nil
}
