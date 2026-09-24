# Phase 10 — Stretch: Two-Tier Simulation

## Status: Not started (stretch goal; do this after the core phases are DoD-verified)

## Approach (design only — not yet implemented)

With a single-node K3s cluster, the two tiers can be simulated with node
labels/taints even before a second physical node exists:

```bash
kubectl label node <node-name> lab-tier=cell-site
kubectl label node <node-name> lab-tier=aggregation
```

Since both labels would collide on one physical node, the practical path is:

1. Add `nodeSelector: {lab-tier: cell-site}` to `edge/manifests/
   ingest-deployment.yaml` and `{lab-tier: aggregation}` to `edge/manifests/
   vlm-deployment.yaml`, and apply **both** labels to the single node for
   now (`kubectl label node <node> lab-tier=cell-site,lab-tier=aggregation`
   doesn't work — a node has one value per label key, so use two different
   keys instead: `cell-site-tier=true` and `aggregation-tier=true`, both on
   the same node until a second node exists).
2. If a second physical machine or VM becomes available, `k3s agent`-join it
   as a real second node, put the smaller-GPU workload (ingestion) on the
   cell-site-tier node and the VLM on the aggregation-tier node, and the
   `nodeSelector`s already in place will route correctly with no other
   change — this is the point of doing it via labels from the start rather
   than hardcoding single-node assumptions into the manifests.

## DoD (once implemented)

- [ ] ingestion and VLM pods are scheduled onto their respective
      `lab-tier` labels (verify with `kubectl get pods -o wide`)
- [ ] Phase 7's end-to-end data path behaves identically to before this
      change (same DoD as phase-7.md)
