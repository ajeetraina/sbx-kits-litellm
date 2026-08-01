# sbx kits for LiteLLM

A standalone [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit (`kind: mixin`) that points a sandbox agent at a [LiteLLM](https://github.com/BerriAI/litellm) proxy running **on the host**, reachable at `host.docker.internal:4000`. The agent gets a single OpenAI-compatible endpoint with:

-> Multi-provider routing (OpenAI, Anthropic, Gemini) with fallback to a local Docker Model Runner model

-> A shared gateway: one router on the host serves every sandbox, instead of installing and running a copy inside each microVM

-> No real API keys inside the microVM: the sandbox holds only a virtual key; real provider credentials live only on the host router

## How it works

```
┌─────────────┐   OPENAI_BASE_URL=host.docker.internal:4000   ┌──────────────────┐
│  sandbox    │ ────────────────────────────────────────────▶ │  LiteLLM router  │
│  (agent)    │            virtual key only                    │  (on the host)   │
└─────────────┘                                                └────────┬─────────┘
                                                          real keys │    │ DMR :12434
                                                    OpenAI/Anthropic/Gemini
```

The kit itself only sets `OPENAI_BASE_URL` to the host router and allows `host.docker.internal:4000` in the sandbox network policy. It does **not** install or start LiteLLM inside the sandbox, the router runs on the host, so provider credentials never enter the microVM.

## Prerequisites

### 1. Start the LiteLLM router on the host

The repo ships a host config (`litellm/config.yaml`) and a compose file. Provider keys live only on the host — put them in a gitignored `.env` file that Compose loads automatically (keeps them out of your shell history):

```
cp .env.example .env      # then edit .env, filling in the providers you use
docker compose up -d
```

This publishes the router on `localhost:4000` (i.e. `host.docker.internal:4000` from a sandbox). Edit `litellm/config.yaml` to add models, change fallbacks, or tune settings.

The image defaults to the public `ghcr.io/berriai/litellm` image. To run the [LiteLLM Docker Hardened Image](https://hub.docker.com/hardened-images/catalog/dhi/litellm) (DHI) instead — minimal, nonroot (UID 65532), CVE-scanned — mirror it into your org (requires a DHI Enterprise subscription) and set the reference in `.env`:

```
LITELLM_IMAGE=your-org/litellm:1        # or a pinned tag like 1.94.0-debian13
```

The shipped `litellm/config.yaml` is world-readable, so the nonroot stable DHI tag can read it; no other changes are needed.

> The sandbox never receives these provider keys — it only holds the virtual `LITELLM_MASTER_KEY`. `sbx secret` is not used here: it injects credentials at a sandbox's egress proxy and never exposes values to a host process, so it can't supply a host-run router. In this design the host owns the provider keys and the sandbox holds only the virtual key.

### 2. (Optional) Enable Docker Model Runner for the local fallback

```
docker model pull ai/gemma3
```

The host router reaches DMR over `host.docker.internal:12434`.

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

The gateway runs on the host, so nothing needs starting inside the sandbox. Check the model list:

```
!curl -s http://host.docker.internal:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | head
```

(`$OPENAI_BASE_URL` already points here, so OpenAI-compatible SDKs work with no extra config.) For a liveness check use `GET /health/liveliness` (returns `I'm alive!`) or `/v1/models` — **not** plain `GET /health`, which returns a benign 500 without a database (see Troubleshooting).

Route a completion through the local model (no cloud keys needed):

```
!curl -s http://host.docker.internal:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-gemma", "messages": [{"role": "user", "content": "hello"}]}'
```

Then the same request with `"model": "gpt-4o"` to confirm the host router's cloud path.

## Why the router runs on the host

A single router on the host is simpler and matches how Docker Model Runner is already consumed: one shared, host-managed gateway that every sandbox reaches over `host.docker.internal`. Real provider keys stay on the host; the sandbox only ever holds a virtual key.

