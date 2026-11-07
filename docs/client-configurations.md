# Client configurations

Pocketd's `/setup` page offers authenticated standard-HTTP examples for curl,
Python and JavaScript, plus Open WebUI's Ollama connection settings. The same
server also works with the clients below. These configurations are free to use;
no additional Pocketd purchase or hosted inference account is needed.

Replace `PHONE`, `KEY` and `MODEL` with the address, API key and model shown on
your phone. Keep the phone on Pocketd while using the server. Never publish the
key or put the server on the public internet.

## Continue

Add this under `models:` in `~/.continue/config.yaml`:

```yaml
models:
  - name: Pocketd
    provider: openai
    model: MODEL
    apiBase: http://PHONE:11434/v1
    apiKey: KEY
```

## opencode

Add a custom provider to `~/.config/opencode/opencode.json`, or a project's
`opencode.json`, then restart opencode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "pocketd": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Pocketd",
      "options": {
        "baseURL": "http://PHONE:11434/v1",
        "apiKey": "KEY"
      },
      "models": {
        "MODEL": { "name": "MODEL" }
      }
    }
  }
}
```

## Aider

```sh
export OPENAI_API_BASE=http://PHONE:11434/v1
export OPENAI_API_KEY=KEY
aider --model openai/MODEL
```

The provider identifiers in these configuration files are required by the
clients. They select an API dialect, not a hosted service: the base URL still
points at your phone, where inference runs. Client-supplied tools are not
implemented; Pocketd's personal-data tools are never available over the network.
