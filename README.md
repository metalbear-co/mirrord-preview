# mirrord Preview GitHub Action

This action allows running [mirrord preview environments](https://metalbear.com/mirrord/docs/use-cases/preview-environments) from your GitHub Actions CI/CD pipeline.

## Quick start

1. Make sure the runner environment has a valid kubeconfig, i.e. `~/.kube/config` is present and the cluster is reachable.
2. Add the following to your job steps:

```yaml
- name: Start preview
  id: preview
  uses: metalbear-co/mirrord-preview@main
  with:
    action: start
    target: deployment/my-app
    namespace: my-namespace        # optional, defaults to current context namespace
    image: myrepo/myapp:latest
    mode: steal                    # optional, defaults to steal
    filter: 'x-preview-id: pr-${{ github.event.pull_request.number }}'
```

To stop the session later, use the `session-key` output:

```yaml
- name: Stop preview
  uses: metalbear-co/mirrord-preview@main
  with:
    action: stop
    key: ${{ steps.preview.outputs.session-key }}
```

## Full PR lifecycle example

```yaml
name: Preview Environment
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  preview-start:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... configure kubeconfig for your cluster ...
      - name: Start preview
        id: start
        uses: metalbear-co/mirrord-preview@main
        with:
          action: start
          target: deployment/my-app
          namespace: staging
          image: myrepo/myapp:${{ github.sha }}
          filter: 'x-preview-id: pr-${{ github.event.pull_request.number }}'
          ports: '[80, 8080]'
          ttl_mins: '60'
          key: 'pr-${{ github.event.pull_request.number }}'

  preview-stop:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      # ... configure kubeconfig for your cluster ...
      - name: Stop preview
        uses: metalbear-co/mirrord-preview@main
        with:
          action: stop
          key: 'pr-${{ github.event.pull_request.number }}'
```

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `action` | **yes** | — | `start` or `stop`. |
| `target` | **yes** (start) | — | Kubernetes target path, e.g. `deployment/my-app`. Maps to [`target`](https://metalbear.com/mirrord/docs/config/options#root-target). |
| `namespace` | no | Current context namespace | Kubernetes namespace of the target. Maps to [`target.namespace`](https://metalbear.com/mirrord/docs/config/options#root-target). |
| `image` | **yes** (start) | — | Container image for the preview pod. Maps to [`feature.preview.image`](https://metalbear.com/mirrord/docs/config/options#feature-preview-image). |
| `mode` | no | `steal` | Traffic mode: `steal` or `mirror`. Maps to [`feature.network.incoming.mode`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming). |
| `filter` | **yes** (start) | — | Header filter regex for incoming HTTP traffic. Maps to [`feature.network.incoming.http_filter.header_filter`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming-http_filter). |
| `ports` | no | — | JSON array of HTTP filter ports, e.g. `[80, 8080]`. Maps to [`feature.network.incoming.http_filter.ports`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming-http_filter). |
| `ttl_mins` | no | — | Session time-to-live in minutes. Integer or `"infinite"`. Passed as a `--ttl` CLI flag. |
| `key` | **yes** (stop) / optional (start) | — | Unique preview session identifier. Auto-generated on start if omitted. |
| `cli_path` | no | — | Path to a pre-existing mirrord binary. Skips downloading the latest release. Useful for testing unreleased builds. |

---

## How it works

This action is a thin wrapper around the `mirrord preview` CLI command. It translates the action inputs into a [`mirrord.json`](https://metalbear.com/mirrord/docs/config/options) configuration file and passes it to `mirrord preview start -f <config>`. Unless `cli_path` is specified, the latest mirrord CLI is used.

For example, given `target: deployment/my-app`, `namespace: staging`, `mode: steal`, `filter: x-preview-id: pr-42`, `ports: [80, 8080]`, and `image: myrepo/myapp:latest`, the generated config is:

```json
{
  "target": {
    "path": "deployment/my-app",
    "namespace": "staging"
  },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": {
          "header_filter": "x-preview-id: pr-42",
          "ports": [80, 8080]
        }
      }
    },
    "preview": {
      "image": "myrepo/myapp:latest"
    }
  }
}
```

The `ttl_mins` and `key` inputs are passed as CLI flags (`--ttl`, `--key`) rather than config fields.

For `action: stop`, the action simply runs `mirrord preview stop --key <key>`.
