# OpenCode Offline / Air-Gapped Mode

Run `opencode serve` on an internal network with no external internet access, using local LLM models that support OpenAI-compatible v1 completion routes. Build your own custom UI that communicates with the OpenCode server API.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Configuration](#configuration)
5. [Environment Variables](#environment-variables)
6. [API Reference](#api-reference)
7. [Building a Custom UI](#building-a-custom-ui)
   - [Architecture](#architecture)
   - [Step 1: SDK Client Setup](#step-1-sdk-client-setup)
   - [Step 2: Session Management](#step-2-session-management)
   - [Step 3: Sending Messages (Async + SSE)](#step-3-sending-messages-async--sse)
   - [Step 4: Parsing SSE Events](#step-4-parsing-sse-events)
   - [Step 5: Rendering Message Parts](#step-5-rendering-message-parts)
   - [Step 6: Loading Session History](#step-6-loading-session-history)
   - [Complete Working Example](#complete-working-example)
8. [Type Definitions](#type-definitions)
9. [Troubleshooting](#troubleshooting)
10. [What Was Changed](#what-was-changed)

---

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

Your custom UI communicates with the OpenCode server over HTTP. The server handles all LLM interactions, tool execution, file operations, and session management. Your UI just needs to send messages and display the streamed responses.

## Prerequisites

OpenCode is built on the [Bun](https://bun.sh) runtime (~100MB single binary).

**Preparing for air-gapped deployment (on an internet-connected machine):**

```bash
# 1. Install Bun
curl -fsSL https://bun.sh/install | bash
# Or download from https://github.com/oven-sh/bun/releases

# 2. Clone and install dependencies
git clone https://github.com/amitok2/opencode.git
cd opencode && bun install

# 3. Build (use local models.json to avoid fetching from models.dev)
cd packages/opencode
MODELS_DEV_API_JSON=../../offline/models.json bun run build --single

# 4. The built binary is at:
#    dist/opencode-<os>-<arch>/bin/opencode
#    (e.g., dist/opencode-linux-x64/bin/opencode)

# 5. Copy to your internal network:
#    - The built binary (self-contained, ~100MB)
#    - The offline/ directory (configs + this README)
```

## Quick Start

1. **Edit the config files** in this directory to match your local model server:
   - `opencode.json` — provider config (baseURL, model name)
   - `models.json` — model capabilities (context window, tool_call support, etc.)

2. **Copy `opencode.json`** to your project directory or `~/.config/opencode/opencode.json`.

3. **Start the server:**
   ```bash
   # Using the convenience script
   ./start.sh

   # Or manually
   OPENCODE_OFFLINE=true \
   OPENCODE_MODELS_PATH=/path/to/models.json \
   ./opencode serve --hostname 0.0.0.0 --port 4096
   ```

4. **Verify:**
   ```bash
   # Health check
   curl http://localhost:4096/global/health
   # {"healthy":true,"version":"..."}

   # List providers (should show your local provider)
   curl http://localhost:4096/provider -H "x-opencode-directory: /tmp/test"

   # Create a session
   curl -X POST http://localhost:4096/session \
     -H "Content-Type: application/json" \
     -H "x-opencode-directory: /tmp/test" \
     -d '{}'
   ```

## Configuration

### opencode.json

Place in your project root or `~/.config/opencode/opencode.json`. Template included in this directory.

Key fields to change:
- **`provider.local.options.baseURL`** — Your model server's OpenAI-compatible endpoint (e.g., `http://10.0.0.5:8080/v1`)
- **`provider.local.models.<id>`** — Model ID must match what your server expects
- **`model`** — Default model as `provider/model` (e.g., `local/llama-3-70b`)

### models.json

Model capability definitions. Point to it via `OPENCODE_MODELS_PATH`. Template included in this directory.

Each model entry needs:
- **`id`** — Must match the model ID your server expects
- **`tool_call`** — `true` if your model supports function calling (required for agentic behavior)
- **`reasoning`** — `true` if your model supports chain-of-thought reasoning
- **`limit.context`** — Maximum context window in tokens
- **`limit.output`** — Maximum output tokens per response

## Environment Variables

| Variable | Description |
|---|---|
| `OPENCODE_OFFLINE=true` | **Required.** Master switch that disables all external network requests |
| `OPENCODE_MODELS_PATH` | Path to local `models.json` with model definitions |
| `OPENCODE_SERVER_PASSWORD` | Optional HTTP basic auth password |
| `OPENCODE_SERVER_USERNAME` | Optional HTTP basic auth username (default: `opencode`) |
| `OPENCODE_CONFIG` | Path to a custom `opencode.json` config file |

`OPENCODE_OFFLINE=true` implies all of these (no need to set separately):
- `OPENCODE_DISABLE_MODELS_FETCH=true`
- `OPENCODE_DISABLE_SHARE=true`
- `OPENCODE_DISABLE_AUTOUPDATE=true`
- `OPENCODE_DISABLE_LSP_DOWNLOAD=true`

## API Reference

All endpoints accept `x-opencode-directory` header to specify the working directory. Without it, the server uses its own cwd.

If `OPENCODE_SERVER_PASSWORD` is set, all requests require HTTP Basic Auth.

**Note:** Use paths **without** trailing slashes (e.g., `/provider` not `/provider/`).

### Core Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/global/health` | GET | Health check |
| `/doc` | GET | Full OpenAPI 3.1 specification (82 routes) |
| `/session` | GET | List all sessions |
| `/session` | POST | Create a new session |
| `/session/:id` | GET | Get session details |
| `/session/:id` | DELETE | Delete a session |
| `/session/:id/message` | GET | List messages in a session |
| `/session/:id/message` | POST | Send a message (sync, blocks until done) |
| `/session/:id/prompt_async` | POST | Send a message (async, returns immediately) |
| `/session/:id/abort` | POST | Abort a running session |
| `/event` | GET | SSE event stream (real-time updates) |
| `/provider` | GET | List providers and models |
| `/agent` | GET | List available agents |
| `/config` | GET | Current configuration |
| `/path` | GET | Working directory info |

---

## Building a Custom UI

### Architecture

```
┌──────────────────┐         HTTP          ┌──────────────┐     OpenAI v1     ┌──────────────┐
│   Your Custom    │  ──── REST API ────►  │   opencode   │  ──────────────►  │  Local LLM   │
│   UI (Browser)   │  ◄──── SSE ────────   │   serve      │  ◄──────────────  │  Server      │
└──────────────────┘                       └──────────────┘                   └──────────────┘
```

The recommended pattern (used by Zip Agent, the reference implementation):

1. **Your UI sends a user message** to OpenCode via `POST /session/:id/prompt_async`
2. **OpenCode processes it** — calls the LLM, executes tools, reads/writes files
3. **Your UI receives real-time updates** via SSE (`GET /event`) — streaming text, tool calls, status changes
4. **When the session goes idle**, the response is complete

This is a **fire-and-listen** pattern: send the prompt asynchronously, then listen for events.

### Step 1: SDK Client Setup

Install the SDK in your UI project:

```bash
npm install @opencode-ai/sdk
```

Create a client:

```typescript
// lib/opencode.ts
import { createOpencodeClient } from "@opencode-ai/sdk/client"

const OPENCODE_URL = process.env.OPENCODE_URL || "http://localhost:4096"

export function getClient() {
  return createOpencodeClient({
    baseUrl: OPENCODE_URL,
  })
}
```

Or without the SDK, use raw `fetch` — all examples below show both approaches.

### Step 2: Session Management

A **session** is a conversation thread. Create one before sending messages.

**With SDK:**
```typescript
const client = getClient()

// Create a session
const { data: session } = await client.session.create()
const sessionId = session.id
// Returns: { id: "ses_xxx", title: "New session - ...", time: { created: ..., updated: ... } }

// List sessions
const { data: sessions } = await client.session.list()
// Returns: Array of session objects

// Delete a session
await client.session.delete({ path: { id: sessionId } })
```

**With raw fetch:**
```typescript
// Create session
const session = await fetch(`${OPENCODE_URL}/session`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-opencode-directory": "/path/to/project",
  },
  body: JSON.stringify({}),
}).then(r => r.json())

// List sessions
const sessions = await fetch(`${OPENCODE_URL}/session`, {
  headers: { "x-opencode-directory": "/path/to/project" },
}).then(r => r.json())
```

### Step 3: Sending Messages (Async + SSE)

This is the core pattern. You do two things simultaneously:

1. **Subscribe to the SSE event stream** to receive real-time updates
2. **Fire the prompt asynchronously** (returns 204 immediately, processing happens in background)

```typescript
async function sendMessage(sessionId: string, message: string): Promise<ReadableStream> {
  const ac = new AbortController()

  const encoder = new TextEncoder()
  const stream = new ReadableStream({
    async start(controller) {
      function send(data: Record<string, unknown>) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`))
      }

      try {
        // 1. Subscribe to backend SSE event stream
        const eventRes = await fetch(`${OPENCODE_URL}/event`, {
          signal: ac.signal,
          headers: {
            Accept: "text/event-stream",
            "x-opencode-directory": "/path/to/project",
          },
        })

        if (!eventRes.ok || !eventRes.body) {
          send({ type: "error", message: "Failed to connect to event stream" })
          controller.close()
          return
        }

        // 2. Fire prompt_async (returns 204, non-blocking)
        fetch(`${OPENCODE_URL}/session/${sessionId}/prompt_async`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-opencode-directory": "/path/to/project",
          },
          body: JSON.stringify({
            parts: [{ type: "text", text: message }],
          }),
          signal: ac.signal,
        }).catch((err) => {
          send({ type: "error", message: "Failed to start prompt" })
        })

        // 3. Parse SSE events from backend
        const reader = eventRes.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ""

        // Track text for delta computation
        const textAccumulator = new Map<string, string>()
        // Track assistant message IDs
        const assistantMsgIds = new Set<string>()

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split("\n")
          buffer = lines.pop() || ""

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue
            const payload = JSON.parse(line.slice(6))
            const eventType = payload.type as string

            // Filter events for our session
            const evtSessionId =
              payload.properties?.sessionID ||
              payload.properties?.part?.sessionID ||
              payload.properties?.info?.sessionID
            if (evtSessionId && evtSessionId !== sessionId) continue

            // Track assistant messages
            if (eventType === "message.updated") {
              const info = payload.properties?.info
              if (info?.role === "assistant") assistantMsgIds.add(info.id)
              continue
            }

            if (eventType === "message.part.updated") {
              const part = payload.properties?.part
              if (!part) continue
              // Skip parts from non-assistant messages
              if (part.messageID && !assistantMsgIds.has(part.messageID)) continue

              const partType = part.type as string
              const partId = part.id || `${partType}-${Date.now()}`

              if (partType === "text") {
                const fullText = (part.text || "") as string
                const prev = textAccumulator.get(partId) || ""
                const delta = fullText.slice(prev.length)
                textAccumulator.set(partId, fullText)
                if (delta) send({ type: "part.text", id: partId, delta, text: fullText })
              } else if (partType === "tool") {
                const state = part.state || {}
                send({
                  type: "part.tool",
                  id: partId,
                  tool: part.tool,
                  status: state.status || "running",
                  input: state.input || {},
                  output: state.output,
                  title: state.title,
                })
              }
            } else if (eventType === "session.idle") {
              send({ type: "done" })
              reader.cancel()
              break
            } else if (eventType === "session.error") {
              send({ type: "error", message: payload.properties?.error || "Session error" })
              reader.cancel()
              break
            }
          }
        }
      } catch (err) {
        if ((err as Error).name !== "AbortError") {
          send({ type: "error", message: (err as Error).message })
        }
      } finally {
        controller.close()
      }
    },
  })

  return stream
}
```

### Step 4: Parsing SSE Events

The OpenCode server emits these SSE event types. Each event is a JSON object wrapped in `data: {...}\n\n` format.

**Events you need to handle:**

| Event Type | Description | Key Properties |
|---|---|---|
| `message.updated` | New message created | `properties.info.role`, `properties.info.id` |
| `message.part.updated` | Part of a message updated (streaming) | `properties.part` (see below) |
| `session.idle` | Session finished processing | Signals response is complete |
| `session.error` | Error during processing | `properties.error` |
| `session.status` | Status change (idle/busy/retry) | `properties.status.type` |

**Message part types in `message.part.updated`:**

| Part Type | Fields | Description |
|---|---|---|
| `text` | `text` | Streamed text response (grows incrementally) |
| `reasoning` | `text` | Model's chain-of-thought (grows incrementally) |
| `tool` | `tool`, `state.status`, `state.input`, `state.output`, `state.title` | Tool call (bash, edit, read, etc.) |
| `step-finish` | `cost`, `tokens` | End of an agentic step with token usage |

**Important:** Text and reasoning parts are sent as **full text each time** (not deltas). To display streaming text, compute the delta yourself:

```typescript
const textAccumulator = new Map<string, string>()

function getDelta(partId: string, fullText: string): string {
  const prev = textAccumulator.get(partId) || ""
  const delta = fullText.slice(prev.length)
  textAccumulator.set(partId, fullText)
  return delta
}
```

### Step 5: Rendering Message Parts

Each assistant message contains multiple **parts**. Render them in order:

```typescript
// Types for your UI state
type StreamPart =
  | { type: "text"; id: string; text: string }
  | { type: "reasoning"; id: string; text: string }
  | {
      type: "tool"
      id: string
      tool: string       // e.g., "bash", "edit", "read", "write", "glob", "grep"
      status: "pending" | "running" | "completed" | "error"
      input: Record<string, unknown>
      output?: string
      title?: string
    }
  | {
      type: "step-finish"
      id: string
      cost: number
      tokens: { input: number; output: number; reasoning: number }
    }

// Update parts array when receiving events
function updateParts(parts: StreamPart[], event: SSEEvent): StreamPart[] {
  const idx = parts.findIndex((p) => p.type === event.type && p.id === event.id)

  if (event.type === "part.text") {
    const part = { type: "text" as const, id: event.id, text: event.text }
    if (idx >= 0) {
      const updated = [...parts]
      updated[idx] = part
      return updated
    }
    return [...parts, part]
  }

  if (event.type === "part.tool") {
    const part = {
      type: "tool" as const,
      id: event.id,
      tool: event.tool,
      status: event.status,
      input: event.input,
      output: event.output,
      title: event.title,
    }
    if (idx >= 0) {
      const updated = [...parts]
      updated[idx] = part
      return updated
    }
    return [...parts, part]
  }

  return parts
}
```

**Rendering in React:**

```tsx
function AssistantMessage({ parts, isLoading }: { parts: StreamPart[]; isLoading: boolean }) {
  return (
    <div>
      {/* Show loading dots while waiting for first part */}
      {parts.length === 0 && isLoading && <LoadingDots />}

      {parts.map((part) => {
        switch (part.type) {
          case "text":
            // Render as Markdown (use react-markdown + remark-gfm)
            return <ReactMarkdown key={part.id}>{part.text}</ReactMarkdown>

          case "reasoning":
            // Show "thinking..." indicator, or render the reasoning text
            return <ThinkingIndicator key={part.id} />

          case "tool":
            return (
              <ToolCallDisplay
                key={part.id}
                tool={part.tool}
                status={part.status}
                input={part.input}
                output={part.output}
                title={part.title}
              />
            )

          case "step-finish":
            return null // Optional: show token usage

          default:
            return null
        }
      })}
    </div>
  )
}
```

### Step 6: Loading Session History

To load messages from a previous session:

**With SDK:**
```typescript
const { data: messages } = await client.session.messages({ path: { id: sessionId } })
// Returns: Array<{ info: Message, parts: Part[] }>

for (const msg of messages) {
  const role = msg.info.role  // "user" or "assistant"
  const parts = msg.parts     // Array of text, tool, reasoning parts
}
```

**With raw fetch:**
```typescript
const messages = await fetch(`${OPENCODE_URL}/session/${sessionId}/message`, {
  headers: { "x-opencode-directory": "/path/to/project" },
}).then(r => r.json())

// Each message: { info: { role, id, sessionID, ... }, parts: [...] }
// User message parts have: { type: "text", text: "..." }
// Assistant message parts have: { type: "text"|"tool"|"reasoning", ... }
// Tool parts have: { type: "tool", tool: "bash", state: { status, input, output, title } }
```

### Complete Working Example

Here is a complete Next.js API route that wraps the OpenCode server (based on Zip Agent):

```typescript
// app/api/chat/route.ts
import { NextRequest } from "next/server"

const OPENCODE_URL = process.env.OPENCODE_URL || "http://localhost:4096"
const PROJECT_DIR = process.env.PROJECT_DIR || "/tmp/my-project"

export async function POST(req: NextRequest) {
  const { message, sessionId: clientSessionId } = await req.json()
  const ac = new AbortController()
  const timeout = setTimeout(() => ac.abort(), 120_000)
  const encoder = new TextEncoder()

  // Create session if needed
  let sessionId = clientSessionId
  if (!sessionId) {
    const session = await fetch(`${OPENCODE_URL}/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-opencode-directory": PROJECT_DIR },
      body: "{}",
    }).then(r => r.json())
    sessionId = session.id
  }

  const stream = new ReadableStream({
    async start(controller) {
      function send(data: Record<string, unknown>) {
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`))
        } catch { /* closed */ }
      }

      try {
        // 1. Subscribe to SSE
        const eventRes = await fetch(`${OPENCODE_URL}/event`, {
          signal: ac.signal,
          headers: { Accept: "text/event-stream", "x-opencode-directory": PROJECT_DIR },
        })
        if (!eventRes.ok || !eventRes.body) {
          send({ type: "error", message: "Failed to connect" })
          controller.close()
          return
        }

        // 2. Fire prompt (non-blocking)
        fetch(`${OPENCODE_URL}/session/${sessionId}/prompt_async`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-opencode-directory": PROJECT_DIR },
          body: JSON.stringify({ parts: [{ type: "text", text: message }] }),
          signal: ac.signal,
        }).catch(() => send({ type: "error", message: "Prompt failed" }))

        // 3. Parse SSE
        const reader = eventRes.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ""
        const textAcc = new Map<string, string>()
        const assistantIds = new Set<string>()

        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split("\n")
          buffer = lines.pop() || ""

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue
            try {
              const payload = JSON.parse(line.slice(6))
              const type = payload.type
              const sid = payload.properties?.sessionID
                || payload.properties?.part?.sessionID
                || payload.properties?.info?.sessionID
              if (sid && sid !== sessionId) continue

              if (type === "message.updated") {
                const info = payload.properties?.info
                if (info?.role === "assistant") assistantIds.add(info.id)
              } else if (type === "message.part.updated") {
                const part = payload.properties?.part
                if (!part || (part.messageID && !assistantIds.has(part.messageID))) continue
                const pid = part.id || `${part.type}-${Date.now()}`

                if (part.type === "text" || part.type === "reasoning") {
                  const full = (part.text || "") as string
                  const prev = textAcc.get(pid) || ""
                  textAcc.set(pid, full)
                  if (full.length > prev.length) {
                    send({ type: `part.${part.type}`, id: pid, delta: full.slice(prev.length), text: full })
                  }
                } else if (part.type === "tool") {
                  const s = part.state || {}
                  send({ type: "part.tool", id: pid, tool: part.tool, status: s.status, input: s.input, output: s.output, title: s.title })
                }
              } else if (type === "session.idle") {
                send({ type: "done" })
                reader.cancel()
                break
              } else if (type === "session.error") {
                send({ type: "error", message: payload.properties?.error })
                reader.cancel()
                break
              }
            } catch { /* skip */ }
          }
        }
      } catch (err) {
        if ((err as Error).name !== "AbortError") {
          send({ type: "error", message: (err as Error).message })
        }
      } finally {
        clearTimeout(timeout)
        try { controller.close() } catch {}
      }
    },
  })

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "X-Session-Id": sessionId,
    },
  })
}
```

And the client-side React component that consumes it:

```tsx
// components/Chat.tsx
"use client"
import { useState, useRef, useCallback } from "react"
import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"

type StreamPart =
  | { type: "text"; id: string; text: string }
  | { type: "tool"; id: string; tool: string; status: string; input: any; output?: string; title?: string }

interface Message {
  role: "user" | "assistant"
  content?: string
  parts: StreamPart[]
  error?: string
}

export default function Chat() {
  const [messages, setMessages] = useState<Message[]>([])
  const [input, setInput] = useState("")
  const [isLoading, setIsLoading] = useState(false)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  const handleSubmit = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    if (!input.trim() || isLoading) return
    const userMessage = input.trim()
    setInput("")
    setIsLoading(true)

    abortRef.current?.abort()
    const ac = new AbortController()
    abortRef.current = ac

    // Add user message + empty assistant placeholder
    setMessages(prev => [
      ...prev,
      { role: "user", content: userMessage, parts: [] },
      { role: "assistant", parts: [] },
    ])

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: userMessage, sessionId }),
        signal: ac.signal,
      })

      const newSessionId = res.headers.get("X-Session-Id")
      if (newSessionId) setSessionId(newSessionId)

      const reader = res.body!.getReader()
      const decoder = new TextDecoder()
      let buffer = ""

      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split("\n")
        buffer = lines.pop() || ""

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue
          try {
            const event = JSON.parse(line.slice(6).trim())
            if (event.type === "done") break
            if (event.type === "error") {
              setMessages(prev => {
                const next = [...prev]
                next[next.length - 1] = { ...next[next.length - 1], error: event.message }
                return next
              })
              break
            }
            // Update the last (assistant) message's parts
            setMessages(prev => {
              const next = [...prev]
              const last = { ...next[next.length - 1] }
              last.parts = updateParts(last.parts, event)
              next[next.length - 1] = last
              return next
            })
          } catch {}
        }
      }
    } catch (err) {
      if ((err as Error).name !== "AbortError") {
        setMessages(prev => {
          const next = [...prev]
          next[next.length - 1] = { ...next[next.length - 1], error: "Connection error" }
          return next
        })
      }
    } finally {
      setIsLoading(false)
    }
  }, [input, isLoading, sessionId])

  return (
    <div>
      {messages.map((msg, i) => (
        <div key={i}>
          {msg.role === "user" ? (
            <p><strong>You:</strong> {msg.content}</p>
          ) : (
            <div>
              {msg.parts.map(part => {
                if (part.type === "text") return <ReactMarkdown key={part.id} remarkPlugins={[remarkGfm]}>{part.text}</ReactMarkdown>
                if (part.type === "tool") return <div key={part.id}>[{part.tool}: {part.status}] {part.title}</div>
                return null
              })}
              {msg.error && <p style={{ color: "red" }}>{msg.error}</p>}
              {msg.parts.length === 0 && !msg.error && isLoading && <p>Thinking...</p>}
            </div>
          )}
        </div>
      ))}
      <form onSubmit={handleSubmit}>
        <input value={input} onChange={e => setInput(e.target.value)} placeholder="Type a message..." />
        <button type="submit" disabled={isLoading}>Send</button>
      </form>
    </div>
  )
}

function updateParts(parts: StreamPart[], event: any): StreamPart[] {
  if (event.type === "part.text") {
    const idx = parts.findIndex(p => p.type === "text" && p.id === event.id)
    const part = { type: "text" as const, id: event.id, text: event.text }
    if (idx >= 0) { const u = [...parts]; u[idx] = part; return u }
    return [...parts, part]
  }
  if (event.type === "part.tool") {
    const idx = parts.findIndex(p => p.type === "tool" && p.id === event.id)
    const part = { type: "tool" as const, id: event.id, tool: event.tool, status: event.status, input: event.input, output: event.output, title: event.title }
    if (idx >= 0) { const u = [...parts]; u[idx] = part; return u }
    return [...parts, part]
  }
  return parts
}
```

## Type Definitions

Full TypeScript types for the SSE event protocol between your UI and the API route:

```typescript
export type ToolStatus = "pending" | "running" | "completed" | "error"

export type StreamPart =
  | { type: "text"; id: string; text: string }
  | { type: "reasoning"; id: string; text: string }
  | {
      type: "tool"
      id: string
      tool: string
      callID: string
      status: ToolStatus
      input: Record<string, unknown>
      output?: string
      title?: string
      time?: { start: number; end?: number }
    }
  | {
      type: "step-finish"
      id: string
      cost: number
      tokens: { input: number; output: number; reasoning: number }
    }

export interface Message {
  role: "user" | "assistant"
  content?: string
  parts: StreamPart[]
  error?: string
}

export type SSEEvent =
  | { type: "part.text"; id: string; delta: string; text: string }
  | { type: "part.reasoning"; id: string; delta: string; text: string }
  | {
      type: "part.tool"
      id: string
      tool: string
      callID: string
      status: ToolStatus
      input: Record<string, unknown>
      output?: string
      title?: string
      time?: { start: number; end?: number }
    }
  | {
      type: "part.step-finish"
      id: string
      cost: number
      tokens: { input: number; output: number; reasoning: number }
    }
  | { type: "error"; message: string }
  | { type: "done" }
```

## Troubleshooting

### Server won't start
- Ensure `OPENCODE_OFFLINE=true` is set before starting
- Check that `OPENCODE_MODELS_PATH` points to a valid JSON file
- Verify your `opencode.json` config is valid (use the template)

### Model not found
- Model ID in `opencode.json` (`model` field) must match `provider/model-id` format (e.g., `local/your-model-name`)
- The model-id must exist in your provider's `models` config
- Check that `enabled_providers` includes your provider ID

### Connection refused to model server
- Verify your local model server is running and accessible
- Check `provider.<name>.options.baseURL` in opencode.json
- Ensure the server supports OpenAI-compatible `/v1/chat/completions`

### No external network requests
- Verify: `echo $OPENCODE_OFFLINE` should print `true`
- Monitor: `sudo tcpdump -i any 'not host 127.0.0.1 and not host localhost' -c 10`
- Ensure no MCP servers in config point to external URLs

### Empty response from /session/:id/message
- The sync message endpoint blocks until completion. If your model server is not reachable, it may return empty.
- Use `prompt_async` + SSE instead (recommended pattern)

### Catch-all returns offline message
Expected behavior. Any unmatched path returns:
```json
{"error":"offline_mode","message":"OpenCode is running in offline mode...","docs":"/doc"}
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
| `packages/opencode/script/build.ts` | Trim models JSON to fix snapshot generation |

### New Files

| File | Purpose |
|---|---|
| `offline/README.md` | This documentation |
| `offline/models.json` | Template model definitions for local models |
| `offline/opencode.json` | Template OpenCode configuration for offline use |
| `offline/start.sh` | Convenience startup script |
