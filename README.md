# sbx kits for LiteLLM

A standalone [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit (`kind: mixin`) that runs a [LiteLLM](https://github.com/BerriAI/litellm) proxy **inside the sandbox** on `localhost:4000`, giving any agent a single OpenAI-compatible endpoint with:

-> Multi-provider routing (OpenAI, Anthropic, Gemini) with fallbacks to a local Docker Model Runner model
-> Zero real API keys inside the microVM: LiteLLM's upstream calls go to known provider hostnames, so the sbx credential proxy injects credentials at egress
-> Spend tracking and retries via LiteLLM's router, without weakening the sandbox security model

## Why in-sandbox and not an external gateway?

The sbx credential proxy only injects secrets for known provider hostnames. An **external** LiteLLM gateway at a custom hostname would require `--bypass-host` plus plaintext env vars, losing MITM visibility and credential injection. That gap is tracked in [docker/roadmap#904](https://github.com/docker/roadmap/issues/904).

Running LiteLLM **inside** the sandbox sidesteps the problem entirely: the agent talks to `localhost:4000`, and LiteLLM's outbound traffic to `api.openai.com`, `api.anthropic.com`, and `generativelanguage.googleapis.com` flows through the credential proxy like any other request. Once #904 lands, this kit can grow an `:external` variant.

## Prerequisites

### 1. Store provider secrets on the host

```
sbx secret import            # or:
echo "$OPENAI_API_KEY" | sbx secret set -g openai
```

### 2. (Optional) Enable Docker Model Runner for the local fallback

```
docker model pull ai/gemma3
```

## Launch

From a local clone (kit lives at the repo root):

```
git clone https://github.com/ajeetraina/sbx-kits-litellm.git
sbx run --kit ./sbx-kits-litellm/ claude
```

Or over git:

```
sbx run --kit "git+https://github.com/ajeetraina/sbx-kits-litellm.git" claude
```

Or from the published kit on Docker Hub (note the explicit `:latest` tag — an
untagged OCI reference is rejected as an invalid reference):

```
sbx run --kit docker.io/ajeetraina777/sbx-kits-litellm:latest claude
```

## Publish the kit

Push the validated kit to a registry as a tag with the helper script:

```
./scripts/push-kit.sh                        # docker.io/<namespace>/sbx-kits-litellm:latest
TAG=v1 ./scripts/push-kit.sh                 # :v1
DOCKERHUB_NAMESPACE=me ./scripts/push-kit.sh # override the namespace
```

It stages `spec.yaml` + `README.md` (+ `LICENSE` if present), runs `sbx kit validate`, then `sbx kit push`. Requires registry auth (`docker login`).

## Verify inside the sandbox

Start the gateway and check the model list:

```
!~/.litellm/start.sh
!curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | head
```

For a liveness check use `GET /health/liveliness` (returns `I'm alive!`) or `/v1/models` — **not** plain `GET /health`, which returns a benign 500 in-sandbox (see Troubleshooting).

Route a completion through the local model (no cloud keys needed):

```
!curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-gemma", "messages": [{"role": "user", "content": "hello"}]}'
```

Then the same request with `"model": "gpt-4o"` to confirm credential injection on the cloud path.

## Troubleshooting

### A cloud model returns an auth error (`local-gemma` works, `gpt-4o`/`claude` don't)

The gateway declares provider hostnames in `caps.network.allow`, but the sbx credential proxy only **injects** a stored secret on a request if that secret is **bound to the domain** in your host-side `~/.config/sbx/credentials.yaml`. If you see a warning like `credential for "openai" discovered but no domains allowed by your bindings; not injecting` at sandbox start, add the binding:

```yaml
bindings:
  openai:
    apiKey:
      domains:
        - api.openai.com
  anthropic:
    apiKey:
      domains:
        - api.anthropic.com
  # gemini (Google AI): bind whatever secret name you stored
  # google:
  #   apiKey:
  #     domains:
  #       - generativelanguage.googleapis.com
```

Import the secrets first (`sbx secret set -g openai`, etc.), then relaunch the sandbox. This is host credential config, independent of the kit.

> Note: a stored **OAuth**-configured `anthropic` credential (e.g. a Claude Code login token) does **not** authenticate direct `api.anthropic.com` API calls and will return `401`. For the `claude` model, store a real Anthropic **API key** (`sbx secret set -g anthropic`).

### A cloud model returns a connection error or falls back to `local-gemma`

If `gpt-4o` errors with something like `httpx.ConnectError: Cannot connect to host localhost:4000` (or silently returns a `local-gemma`/`model.gguf` response via the fallback), the culprit is `OPENAI_BASE_URL`. This kit sets `OPENAI_BASE_URL=http://localhost:4000/v1` so in-sandbox tooling talks to the gateway — but **LiteLLM's own OpenAI client inherits that env var too**, so an `openai/*` model with no explicit `api_base` loops its upstream call back to the gateway itself.

Every cloud model on the `openai/` provider must pin its real upstream in `config.yaml`:

```yaml
- model_name: gpt-4o
  litellm_params:
    model: openai/gpt-4o
    api_base: "https://api.openai.com/v1"   # required, or it loops back to localhost:4000
    api_key: "proxy-managed"
```

(Models with their own `api_base` — like the `local-gemma` DMR entry — are unaffected. `anthropic/*` and `gemini/*` models use provider-specific base URLs and don't read `OPENAI_BASE_URL`.)

### A cloud call fails with `No connected db` / `ModuleNotFoundError: No module named 'prisma'`

There is no database in the sandbox, and `litellm[proxy]` doesn't bundle `prisma`, so LiteLLM's DB-backed spend/error logging crashes when it tries to persist a cost-mapped call (which is why `local-gemma` — cost 0 — is unaffected). The kit disables it in `general_settings`:

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  disable_spend_logs: true
  disable_error_logs: true
```

If you re-enable spend tracking, you must also provision a database and install the `prisma` client.

### `GET /health` returns `500 Internal server error`

Expected in-sandbox — **not** a sign the gateway is down. Plain `/health` runs LiteLLM's DB-backed active health checks, which fail because there is no database (same root cause as above). Use `GET /health/liveliness` (returns `I'm alive!`), `GET /health/readiness`, or `GET /v1/models` to confirm the proxy is serving.

### `sbx create` fails with `500 ... failed to run sandbox container`

Usually an install-command failure aborting provisioning. This kit installs LiteLLM under a pinned **Python 3.12** virtualenv via `uv` on purpose: the base image ships Python 3.14, for which some LiteLLM deps (e.g. `orjson`, `uvloop`) have no prebuilt wheels and would try to build from source (needing Rust/C toolchains and extra egress that the sandbox network policy blocks). If you change the install commands, keep them on a wheel-friendly Python. Inspect the daemon log at `~/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/daemon.log` to see the underlying error.

