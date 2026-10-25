package compile

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strings"

	"core/backend/authoring"
	"core/profilecodec"
	"github.com/metacubex/age"
	"github.com/metacubex/age/armor"
)

// RuleSetResult is the pure root-helper contract. Content is the optional MRS
// representation; empty Content keeps the original bytes and declared format.
type RuleSetResult struct {
	Behavior string `json:"behavior"`
	Format   string `json:"format"`
	Content  []byte `json:"-"`
}
type RuleSetCompiler func(context.Context, []byte) (RuleSetResult, error)

// DecodeProfile decrypts only the supplied identity; global engine age keys
// cannot leak into backend validation. Plain YAML remains compatible.
func DecodeProfile(ctx context.Context, source, secret string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if !strings.HasPrefix(source, armor.Header) {
		return source, nil
	}
	identities, err := age.ParseIdentities(strings.NewReader(secret))
	if err != nil {
		return "", err
	}
	reader, err := age.Decrypt(armor.NewReader(strings.NewReader(source)), identities...)
	if err != nil {
		return "", err
	}
	data, err := io.ReadAll(io.LimitReader(reader, 16<<20+1))
	if err != nil {
		return "", err
	}
	if len(data) > 16<<20 {
		return "", errors.New("decrypted profile exceeds size limit")
	}
	return string(data), ctx.Err()
}
func RuleResourceBytes(row authoring.Object) ([]byte, bool, error) {
	if encoded := authoring.String(row, "contentBase64"); encoded != "" {
		data, err := base64.StdEncoding.DecodeString(encoded)
		return data, true, err
	}
	if raw, present := row["content"]; present && string(raw) != "null" {
		return []byte(authoring.String(row, "content")), true, nil
	}
	return nil, false, nil
}
func DecodeLinks(ctx context.Context, source string) ([]Object, error) {
	lines := []string{}
	for _, line := range strings.Split(source, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			lines = append(lines, line)
		}
	}
	results := profilecodec.DecodeLinks(lines)
	proxies := []Object{}
	for i, rows := range results {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if len(rows) == 0 {
			return nil, fmt.Errorf("unreadable share link at line %d", i+1)
		}
		for _, row := range rows {
			proxies = append(proxies, Object(row))
		}
	}
	if len(proxies) == 0 {
		return nil, errors.New("no share links supplied")
	}
	return proxies, nil
}
func CompileRules(ctx context.Context, data []byte) (RuleSetResult, error) {
	if err := ctx.Err(); err != nil {
		return RuleSetResult{}, err
	}
	if len(data) > 16<<20 {
		return RuleSetResult{}, errors.New("rule resource exceeds size limit")
	}
	info, mrs, err := profilecodec.CompileRules(data, true)
	if err != nil {
		return RuleSetResult{}, err
	}
	return RuleSetResult{Behavior: info.Behavior, Format: info.Format, Content: mrs}, ctx.Err()
}
func (c *Compiler) CompileResource(ctx context.Context, data []byte) (RuleSetResult, error) {
	if c.CompileRuleSet != nil {
		return c.CompileRuleSet(ctx, data)
	}
	return CompileRules(ctx, data)
}
func (c *Compiler) ParseLinks(ctx context.Context, source string) ([]Object, error) {
	if c.DecodeShareLinks != nil {
		return c.DecodeShareLinks(ctx, source)
	}
	return DecodeLinks(ctx, source)
}
