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

## Verify inside the sandbox

Start the gateway and check the model list:

```
!~/.litellm/start.sh
!curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | head
```

Route a completion through the local model (no cloud keys needed):

```
!curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-gemma", "messages": [{"role": "user", "content": "hello"}]}'
```

Then the same request with `"model": "gpt-4o"` to confirm credential injection on the cloud path.

## Open items to validate before publishing (tested-commands rule)

1. **Start hook**: this kit ships a `start.sh` launcher because it is unconfirmed whether the kit spec supports a boot/service hook in addition to `commands.install`. Check `spec/` in docker/sbx-kits-contrib and run the TCK; if a start hook exists, move the launcher there.
2. **Header overwrite semantics**: confirm the credential proxy replaces the placeholder `api_key: "proxy-managed"` auth headers rather than only injecting when absent. If it only injects when the header is missing, test with empty api_key values.
3. **TLS trust for httpx**: LiteLLM uses httpx, which reads the certifi bundle rather than the system trust store. Confirm the sandbox exports `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` pointing at the proxy CA; if not, set them in `environment.variables`.
4. **Version pin**: pin `litellm[proxy]` to the exact version validated in the sandbox.

## License

Apache-2.0
