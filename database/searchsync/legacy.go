package main

import (
	"errors"
	"fmt"
	"strings"
)

func legacyTags(data, table string) ([]string, error) {
	prefix := "table public." + table + ": "
	if !strings.HasPrefix(data, prefix) {
		return nil, nil
	}
	rest := strings.TrimPrefix(data, prefix)
	colon := strings.IndexByte(rest, ':')
	if colon < 0 {
		return nil, errors.New("malformed legacy operation")
	}
	op := rest[:colon]
	rest = rest[colon+1:]
	if op != "INSERT" && op != "UPDATE" && op != "DELETE" {
		return nil, fmt.Errorf("unsupported legacy source operation %s", op)
	}
	var tags []string
	for len(strings.TrimSpace(rest)) > 0 {
		rest = strings.TrimSpace(rest)
		if strings.HasPrefix(rest, "old-key:") {
			rest = rest[len("old-key:"):]
			continue
		}
		if strings.HasPrefix(rest, "new-tuple:") {
			rest = rest[len("new-tuple:"):]
			continue
		}
		bracket := strings.IndexByte(rest, '[')
		if bracket < 1 {
			return nil, errors.New("malformed legacy column")
		}
		name := rest[:bracket]
		end := strings.Index(rest[bracket:], "]:")
		if end < 0 {
			return nil, errors.New("malformed legacy type")
		}
		rest = rest[bracket+end+2:]
		value := ""
		if strings.HasPrefix(rest, "'") {
			rest = rest[1:]
			var b strings.Builder
			closed := false
			for len(rest) > 0 {
				if rest[0] == '\'' {
					if len(rest) > 1 && rest[1] == '\'' {
						b.WriteByte('\'')
						rest = rest[2:]
						continue
					}
					rest = rest[1:]
					closed = true
					break
				}
				b.WriteByte(rest[0])
				rest = rest[1:]
			}
			if !closed {
				return nil, errors.New("unterminated legacy value")
			}
			value = b.String()
		} else {
			end := strings.IndexByte(rest, ' ')
			if end < 0 {
				value = rest
				rest = ""
			} else {
				value = rest[:end]
				rest = rest[end:]
			}
		}
		if name == "tag" {
			if value == "" || value == "null" {
				return nil, errors.New("legacy tag missing")
			}
			tags = append(tags, value)
		}
	}
	if len(tags) == 0 {
		return nil, errors.New("legacy source change lacks tag")
	}
	return tags, nil
}
