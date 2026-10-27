#!/usr/bin/env python3
"""
Convert CustomResourceDefinitions into JSON schemas kubeconform can use, so
the Gateway API / Envoy Gateway resources in edge/manifests/ are validated as
strictly as built-in kinds (CI and CLAUDE.md "Commands").

  python3 scripts/crd-schemas.py <crds.yaml> <out-dir>
  kubeconform -strict -schema-location default \
    -schema-location '<out-dir>/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' ...

Objects that declare properties get additionalProperties: false (unless they
preserve unknown fields), which is what makes -strict catch typos.
"""
import json
import os
import sys

import yaml


def strict(node):
    if isinstance(node, dict):
        if (node.get("type") == "object" and "properties" in node
                and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def main(src, out):
    os.makedirs(out, exist_ok=True)
    count = 0
    with open(src) as f:
        for doc in yaml.safe_load_all(f):
            if not doc or doc.get("kind") != "CustomResourceDefinition":
                continue
            kind = doc["spec"]["names"]["kind"].lower()
            for v in doc["spec"]["versions"]:
                schema = strict(v["schema"]["openAPIV3Schema"])
                # apiVersion/kind/metadata are validated by the API server itself.
                for k in ("apiVersion", "kind", "metadata"):
                    schema.setdefault("properties", {}).setdefault(k, {})
                with open(os.path.join(out, f"{kind}_{v['name']}.json"), "w") as o:
                    json.dump(schema, o)
                count += 1
    print(f"wrote {count} schemas to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
