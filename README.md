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
    key: pr-${{ github.event.pull_request.number }}
```

The `{{ key }}` in the filter is replaced with the value of `key`, so each PR gets its own isolated preview session. To stop the session later:
```yaml
- name: Stop preview
  uses: metalbear-co/mirrord-preview@main
  with:
    action: stop
    key: pr-${{ github.event.pull_request.number }}
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
        uses: metalbear-co/mirrord-preview@main
        with:
          action: start
          target: deployment/my-app
          namespace: staging
          image: myrepo/myapp:${{ github.sha }}
          ports: '[80, 8080]'
          ttl_mins: '60'
          key: pr-${{ github.event.pull_request.number }}

  preview-stop:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      # ... configure kubeconfig for your cluster ...
      - name: Stop preview
        uses: metalbear-co/mirrord-preview@main
        with:
          action: stop
          key: pr-${{ github.event.pull_request.number }}
```

### Using `extra_config`
```yaml
- name: Start preview
  uses: metalbear-co/mirrord-preview@main
  with:
    action: start
    target: deployment/my-app
    image: myrepo/myapp:latest
    filter: 'x-preview-id: {{ key }}'
    key: pr-${{ github.event.pull_request.number }}
    extra_config: |
      {
        "feature": {
          "copy_target": {
            "scale_down": true
          }
        }
      }
```

---

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `action` | **yes** | `start` or `stop`. |
| `target` | **yes** (start) | Kubernetes target path, e.g. `deployment/my-app`. Maps to [`target.path`](https://metalbear.com/mirrord/docs/config/options#target-path). |
| `namespace` | no | Kubernetes namespace of the target. Defaults to current context namespace. Maps to [`target.namespace`](https://metalbear.com/mirrord/docs/config/options#target-namespace). |
| `image` | **yes** (start) | Container image for the preview pod. Maps to [`feature.preview.image`](https://metalbear.com/mirrord/docs/config/options#feature-preview-image). |
| `mode` | no | Traffic mode: `steal` or `mirror`. Defaults to `steal`. Maps to [`feature.network.incoming.mode`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming). |
| `filter` | no | Header filter regex for incoming HTTP traffic. Use `{{ key }}` to reference the session key. Defaults to `baggage: *.mirrord-session={{key}}.*`. Maps to [`feature.network.incoming.http_filter.header_filter`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming-http_filter). |
| `ports` | no | Optional JSON array of incoming ports, e.g. `[80, 8080]`. Maps to [`feature.network.incoming.ports`](https://metalbear.com/mirrord/docs/config/options#feature-network-incoming-ports). |
| `ttl_mins` | no | Session time-to-live in minutes. Integer or `"infinite"`. Maps to [`feature.preview.ttl_mins`](https://metalbear.com/mirrord/docs/config/options#feature-preview-ttl_mins). |
| `key` | **yes** (stop) / optional (start) | Unique preview session identifier. Auto-generated on start if omitted. Referenced by `{{ key }}` in the filter. Maps to top-level [`key`](https://metalbear.com/mirrord/docs/config/options#root-key). |
| `cli_path` | no | Path to a pre-existing mirrord binary. Skips downloading the latest release. Useful for testing unreleased builds. |
| `extra_config` | no | JSON object deep-merged into the generated `mirrord.json`. Allows setting any [mirrord config option](https://metalbear.com/mirrord/docs/config/options). Overlapping fields override the generated values. |

---

## How it works

This action is a thin wrapper around the `mirrord preview` CLI command. It translates the action inputs into a [`mirrord.json`](https://metalbear.com/mirrord/docs/config/options) configuration file and passes it to `mirrord preview start -f <config>`. Unless `cli_path` is specified, the latest mirrord CLI is used.

For example, given `target: deployment/my-app`, `namespace: staging`, `mode: steal`, `filter: 'x-traffic: mirrord-session={{ key }}'`, `key: pr-42`, `ports: '[80, 8080]'`, `ttl_mins: '60'`, and `image: myrepo/myapp:latest`, the generated config is:
```json
{
  "key": "pr-42",
  "target": {
    "path": "deployment/my-app",
    "namespace": "staging"
  },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "ports": [80, 8080],
        "http_filter": {
          "header_filter": "x-traffic: mirrord-session={{ key }}"
        }
      }
    },
    "preview": {
      "image": "myrepo/myapp:latest",
      "ttl_mins": 60
    }
  }
}
```

If `extra_config` is provided, it is deep-merged on top of the generated config, allowing any [mirrord config option](https://metalbear.com/mirrord/docs/config/options) to be added or overridden.

For `action: stop`, the action simply runs `mirrord preview stop --key <key>`.
