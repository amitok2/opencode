# OpenCode Offline / Air-Gapped Mode

Run `opencode serve` on an internal network with no external internet access, using local LLM models that support OpenAI-compatible v1 completion routes.

## Overview

When `OPENCODE_OFFLINE=true` is set, OpenCode disables all external network requests:

- Model registry fetching (models.dev)
- Web UI proxy (app.opencode.ai)
- Share service
- Auto-update checks
- LSP server downloads
- Remote .well-known config fetching
- Remote instruction fetching (URL-based instructions)
- Remote skill discovery
- Web search and code search tools

## Prerequisites

OpenCode is built on the [Bun](https://bun.sh) runtime. You need Bun available on your internal network.

**Preparing for air-gapped deployment (on an internet-connected machine):**

```bash
# 1. Download Bun as a standalone binary
curl -fsSL https://bun.sh/install | bash
# Or download directly from https://github.com/oven-sh/bun/releases

# 2. Install OpenCode dependencies
cd opencode && bun install

# 3. Build
cd packages/opencode && bun run build

# 4. Copy to internal network:
#    - The bun binary (~100MB standalone)
#    - The opencode directory (with node_modules)
#    - Or just the built binary from the build output
```

Bun is a single self-contained binary — just copy it to your internal machine and add it to `PATH`.

## Quick Start

1. **Edit the template config files** in this directory to point to your local model server:
   - `opencode.json` — main configuration (provider, model, baseURL)
   - `models.json` — model definitions (capabilities, limits, costs)

2. **Copy `opencode.json`** to your project directory or `~/.config/opencode/opencode.json`.

3. **Start the server:**
   ```bash
   # Using the convenience script
   ./start.sh

   # Or manually
   OPENCODE_OFFLINE=true \
   OPENCODE_MODELS_PATH=/path/to/models.json \
   opencode serve --hostname 0.0.0.0 --port 4096
   ```

4. **Verify it works:**
   ```bash
   curl http://localhost:4096/global/health
   # {"healthy":true,"version":"..."}
   ```

## Environment Variables Reference

| Variable | Description |
|---|---|
| `OPENCODE_OFFLINE=true` | Master switch — disables all external network requests |
| `OPENCODE_MODELS_PATH` | Path to a local `models.json` file with model definitions |
| `OPENCODE_MODELS_URL` | Override the models registry URL (alternative to MODELS_PATH) |
| `OPENCODE_SERVER_PASSWORD` | Optional HTTP basic auth password for the server |
| `OPENCODE_SERVER_USERNAME` | Optional HTTP basic auth username (default: `opencode`) |
| `OPENCODE_CONFIG` | Path to a custom `opencode.json` config file |
| `OPENCODE_CONFIG_CONTENT` | Inline JSON config content (overrides file-based config) |

Setting `OPENCODE_OFFLINE=true` implies the following individual flags, so you don't need to set them separately:

- `OPENCODE_DISABLE_MODELS_FETCH=true`
- `OPENCODE_DISABLE_SHARE=true`
- `OPENCODE_DISABLE_AUTOUPDATE=true`
- `OPENCODE_DISABLE_LSP_DOWNLOAD=true`

## Configuration

### opencode.json

Place this in your project root or `~/.config/opencode/opencode.json`. See the template `opencode.json` in this directory.

Key fields:
- **`provider.<name>.options.baseURL`** — Your local model server's OpenAI-compatible endpoint
- **`provider.<name>.npm`** — Use `@ai-sdk/openai-compatible` for OpenAI-compatible servers
- **`model`** — Default model in `provider/model` format (e.g., `local/your-model-name`)
- **`enabled_providers`** — Restrict to only your local provider(s)
- **`share`** — Set to `"disabled"`
- **`autoupdate`** — Set to `false`

### models.json

This file defines model capabilities. Point to it via `OPENCODE_MODELS_PATH`. See the template `models.json` in this directory.

Each model entry needs:
- **`id`** — Must match the model ID your server expects
- **`tool_call`** — Set to `true` if your model supports function calling
- **`reasoning`** — Set to `true` if your model supports chain-of-thought reasoning
- **`limit.context`** — Maximum context window size in tokens
- **`limit.output`** — Maximum output tokens

## API Reference

All endpoints accept `x-opencode-directory` header to specify the working directory. If `OPENCODE_SERVER_PASSWORD` is set, all requests require HTTP Basic Auth.

### Health Check

```
GET /global/health
```

Returns: `{"healthy": true, "version": "..."}`

### Session Management

**Create a session:**
```
POST /session/
Content-Type: application/json
x-opencode-directory: /path/to/project

{}
```

**List sessions:**
```
GET /session/
x-opencode-directory: /path/to/project
```

**Get a session:**
```
GET /session/:id
x-opencode-directory: /path/to/project
```

**Delete a session:**
```
DELETE /session/:id
x-opencode-directory: /path/to/project
```

### Sending Messages (Streaming)

```
POST /session/:id/message
Content-Type: application/json
x-opencode-directory: /path/to/project

{
  "parts": [
    {"type": "text", "text": "Hello, what can you do?"}
  ]
}
```

The response is a stream of newline-delimited JSON objects. Use `--no-buffer` with curl to see them in real-time.

### SSE Event Subscription

```
GET /event
x-opencode-directory: /path/to/project
```

Returns a Server-Sent Events stream. Events include session updates, message updates, part updates, and more.

### Providers and Models

**List providers:**
```
GET /provider/
x-opencode-directory: /path/to/project
```

### Authentication

**Set auth credentials:**
```
PUT /auth/:providerID
Content-Type: application/json

{"type": "api_key", "token": "..."}
```

**Remove auth credentials:**
```
DELETE /auth/:providerID
```

### Other Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/doc` | GET | OpenAPI specification |
| `/path` | GET | Working directory and path info |
| `/vcs` | GET | VCS (git) info |
| `/command` | GET | List available commands |
| `/agent` | GET | List available agents |
| `/skill` | GET | List available skills |
| `/lsp` | GET | LSP server status |
| `/config/` | GET | Current configuration |
| `/instance/dispose` | POST | Dispose current instance |

## Streaming Guide

### Using fetch with ReadableStream (JavaScript/TypeScript)

```typescript
const response = await fetch("http://localhost:4096/session/SESSION_ID/message", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-opencode-directory": "/path/to/project",
  },
  body: JSON.stringify({
    parts: [{ type: "text", text: "Hello!" }],
  }),
})

const reader = response.body!.getReader()
const decoder = new TextDecoder()

while (true) {
  const { done, value } = await reader.read()
  if (done) break

  const chunk = decoder.decode(value, { stream: true })
  const lines = chunk.split("\n").filter(Boolean)
  for (const line of lines) {
    const event = JSON.parse(line)
    console.log(event.type, event)
  }
}
```

### Using SSE for Real-Time Events

```typescript
const eventSource = new EventSource(
  "http://localhost:4096/event?directory=/path/to/project"
)

eventSource.onmessage = (event) => {
  const data = JSON.parse(event.data)
  console.log(data.type, data)
}

eventSource.onerror = (err) => {
  console.error("SSE error:", err)
}
```

### Using the Official SDK

```typescript
import { OpenCode } from "@opencode-ai/sdk"

const client = new OpenCode({
  baseURL: "http://localhost:4096",
})

// Create a session
const session = await client.session.create({
  directory: "/path/to/project",
})

// Send a message
const stream = await client.session.chat(session.id, {
  parts: [{ type: "text", text: "Hello!" }],
  directory: "/path/to/project",
})
```

## Building a Custom UI

1. **Use the `@opencode-ai/sdk` package** (`packages/sdk/js/` in this repo) for type-safe API access
2. **Connect to SSE** (`GET /event`) for real-time updates (session changes, message parts, etc.)
3. **Send messages** via `POST /session/:id/message` and consume the streaming response
4. **Use WebSockets** for PTY terminal sessions (`/pty` routes)

### Recommended Architecture

```
┌──────────────┐     HTTP/SSE      ┌──────────────┐     OpenAI v1     ┌──────────────┐
│  Custom UI   │ ◄──────────────► │ opencode      │ ◄──────────────► │ Local LLM    │
│  (Browser)   │                   │ serve         │                   │ Server       │
└──────────────┘                   └──────────────┘                   └──────────────┘
```

## Troubleshooting

### Server won't start
- Ensure `OPENCODE_OFFLINE=true` is set before starting
- Check that `OPENCODE_MODELS_PATH` points to a valid JSON file
- Verify your `opencode.json` config is valid (use the template as a starting point)

### Model not found
- Ensure the model ID in `opencode.json` (`model` field) matches a model defined in your provider config
- Format: `provider-id/model-id` (e.g., `local/your-model-name`)
- Check that `enabled_providers` includes your provider ID

### Connection refused to model server
- Verify your local model server is running and accessible
- Check that `provider.<name>.options.baseURL` is correct
- Ensure the model server supports OpenAI-compatible `/v1/chat/completions`

### Unexpected external network requests
- Verify `OPENCODE_OFFLINE=true` is set (check with `echo $OPENCODE_OFFLINE`)
- Monitor with: `sudo tcpdump -i any 'not host 127.0.0.1 and not host localhost' -c 10`
- Check that no MCP servers are configured that point to external URLs

### Catch-all route returns offline message
This is expected. In offline mode, any path not matching a known API route returns:
```json
{
  "error": "offline_mode",
  "message": "OpenCode is running in offline mode. The web UI is not available. Use the API endpoints directly.",
  "docs": "/doc"
}
```

## What Was Changed

### Modified Files

| File | Change |
|---|---|
| `packages/opencode/src/flag/flag.ts` | Added `OPENCODE_OFFLINE` flag |
| `packages/opencode/src/server/server.ts` | Guard proxy catch-all with offline check |
| `packages/opencode/src/provider/models.ts` | Guard model registry fetch and refresh interval |
| `packages/opencode/src/share/share.ts` | Added offline to disabled check |
| `packages/opencode/src/share/share-next.ts` | Added offline to disabled check |
| `packages/opencode/src/cli/upgrade.ts` | Added offline to auto-update skip check |
| `packages/opencode/src/config/config.ts` | Guard .well-known config fetch |
| `packages/opencode/src/session/instruction.ts` | Guard remote URL instruction fetch |
| `packages/opencode/src/skill/discovery.ts` | Guard remote skill pull |
| `packages/opencode/src/tool/websearch.ts` | Return offline message |
| `packages/opencode/src/tool/codesearch.ts` | Return offline message |

### New Files

| File | Purpose |
|---|---|
| `offline/README.md` | This documentation |
| `offline/models.json` | Template model definitions for local models |
| `offline/opencode.json` | Template OpenCode configuration for offline use |
| `offline/start.sh` | Convenience startup script |
