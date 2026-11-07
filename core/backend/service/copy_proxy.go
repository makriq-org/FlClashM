package service

import (
	"context"
	"encoding/json"
	"errors"

	"core/backend/authoring"
	"core/backend/compile"
)

func (a *App) copyProxy(ctx context.Context, params json.RawMessage) (Receipt, error) {
	var p struct {
		Name string `json:"name"`
	}
	if err := decodeParams(params, &p); err != nil {
		return Receipt{}, err
	}
	if p.Name == "" || len(p.Name) > 1024 {
		return Receipt{}, errors.New("proxy name required")
	}
	if a.readProxyDefinition == nil {
		return Receipt{}, errors.New("proxy definitions unavailable")
	}
	var definition map[string]any
	plan, input, err := a.runtime.Applied()
	if err != nil {
		return Receipt{}, err
	}
	if plan != nil {
		var prepared compile.Prepared
		if json.Unmarshal(plan.Payload(), &prepared) == nil {
			for _, node := range prepared.Nodes {
				if node.Name == p.Name {
					inspection, inspectErr := a.compiler.InspectProfile(ctx, input)
					if inspectErr != nil {
						return Receipt{}, inspectErr
					}
					for _, value := range listValue(inspection.Config["proxies"]) {
						proxy := mapValue(value)
						if proxy["name"] == p.Name {
							definition = map[string]any(proxy)
							break
						}
					}
					if definition == nil {
						return Receipt{}, errors.New("original node definition unavailable")
					}
				}
			}
		}
	}
	if definition == nil {
		definition, err = a.readProxyDefinition(ctx, p.Name)
		if err != nil {
			return Receipt{}, err
		}
	}
	if len(definition) == 0 {
		return Receipt{}, errors.New("proxy definition unavailable")
	}
	snapshot := a.profiles.AuthoringSnapshot()
	comparable := proxyComparable(compile.Object(definition))
	taken := map[string]bool{"DIRECT": true, "REJECT": true, "GLOBAL": true, "PASS": true}
	for _, row := range snapshot.Collections["customProxies"] {
		existing := mapValue(authoring.Decode(row)["definition"])
		if proxyComparable(existing) == comparable {
			return Receipt{Revision: snapshot.Revision}, nil
		}
		taken[textValue(existing["name"])] = true
	}
	for _, row := range snapshot.Collections["proxyGroups"] {
		taken[authoring.String(row, "name")] = true
	}
	definition["name"] = freeName(p.Name, taken)
	delete(definition, "dialer-proxy")
	snapshot.Collections["customProxies"] = append(snapshot.Collections["customProxies"], authoring.Object{"id": jsonValue(newDeclarationID()), "definition": jsonValue(definition)})
	if err = a.profiles.ReplaceAuthoring(ctx, snapshot.Collections, snapshot.Revision); err != nil {
		return Receipt{}, err
	}
	a.publish()
	return Receipt{Revision: a.profiles.Snapshot().Revision}, nil
}
