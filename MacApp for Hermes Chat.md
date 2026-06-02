# **Native Hermes Mac App**

## **Goal**

Build a native macOS chat app for Hermes that feels lightweight, Mac-native, and low-overhead while keeping Hermes as the backend brain.

## **Product direction**

* native macOS app, not a browser-first UI  
* low system resource usage is a hard requirement  
* nostalgic AIM-style flavor is welcome, but not at the expense of performance  
* SwiftUI is the preferred frontend approach  
* Hermes remains the source of truth for sessions, profiles, tools, and memory

## **Recommended architecture**

SwiftUI app  
 → local bridge layer  
 → Hermes runtime  
 → models, tools, memory, sessions

### **Frontend**

Use:

* SwiftUI  
* AppKit only where needed  
* async/await for app state and streaming updates

Core UI pieces:

* sidebar for agents and sessions  
* main chat pane  
* composer input  
* lightweight status row  
* optional collapsible tool activity drawer later

### **Bridge layer**

Recommended shape:

* local-only bridge  
* Python \+ FastAPI  
* binds to 127.0.0.1 only  
* SSE for streaming responses  
* default port: 8765

Why this layer exists:

* keeps the Mac app thin  
* isolates Hermes process management  
* gives the SwiftUI app a stable contract  
* leaves room for future clients without rewriting the app core

### **Hermes runtime responsibilities**

Hermes should own:

* model calls  
* tool execution  
* memory  
* session history  
* profiles and specialist behavior  
* background workflows

The Mac app should own:

* presentation  
* interaction  
* session browsing  
* streaming display  
* notifications  
* lightweight local UI cache

## **Native vs heavy web shell decision**

Recommended:

* SwiftUI native app  
* avoid Electron for this use case

Reason:

* lower memory footprint  
* more Mac-native feel  
* less background overhead

## **Session model**

* one app conversation maps to one bridge session  
* each bridge session maps internally to a Hermes session reference  
* agent selection determines the Hermes profile/persona used by default  
* Hermes remains the source of truth for transcript history

## **Initial agent model**

Primary default:

* Callie as the front desk / main coordinator

Selectable specialists later:

* Lyra  
* Piper  
* Sage  
* Vivian  
* Zero

## **Resource-efficiency rules**

* keep the SwiftUI app thin  
* do not keep multiple Hermes workers hot unless needed  
* lazy-load session history  
* keep detailed tool traces collapsed by default  
* use one active stream at a time in v1  
* avoid a bundled browser engine

## **MVP build plan**

### **Phase 0 — MVP definition**

MVP includes:

* native SwiftUI window  
* session sidebar  
* chat pane  
* text input  
* streamed replies  
* new/select conversation  
* persona selection  
* basic error handling

### **Phase 1 — bridge first**

Build:

* health endpoint  
* session list/create/read  
* send message endpoint  
* streaming endpoint  
* cancellation endpoint

### **Phase 2 — Mac app shell**

Build:

* sidebar  
* chat view  
* composer  
* message rendering  
* loading and error states

### **Phase 3 — connect app to bridge**

Wire:

* health check  
* session loading  
* send message  
* stream handling  
* final message persistence

### **Phase 4 — session quality**

Add:

* titles/snippets  
* reopen existing sessions  
* local cache for summaries  
* retry and failure states

### **Phase 5 — persona support**

Add:

* agent chooser  
* agent header state  
* specialist routing flavor

### **Phase 6 — native polish**

Later:

* keyboard shortcuts  
* notifications  
* settings window  
* menu bar quick-open  
* optional tool activity drawer

## **Bridge API contract**

Base URL:

* [http://127.0.0.1:8765](http://127.0.0.1:8765)

Transport:

* HTTP JSON for request/response  
* Server-Sent Events for streaming

### **MVP endpoints**

* GET /health  
* GET /agents  
* GET /sessions  
* POST /sessions  
* GET /sessions/{session\_id}  
* POST /chat/send  
* GET /chat/stream/{request\_id}  
* POST /chat/cancel/{request\_id}

## **Canonical bridge entities**

### **Agent**

Fields:

* id  
* display\_name  
* profile  
* role  
* description  
* available

### **SessionSummary**

Fields:

* id  
* agent\_id  
* title  
* preview  
* updated\_at  
* message\_count

### **Message**

Fields:

* id  
* role  
* content  
* created\_at  
* optional metadata

### **ChatRequest**

Fields:

* session\_id  
* agent\_id  
* message  
* stream

### **RequestHandle**

Fields:

* request\_id  
* session\_id  
* stream\_url  
* status

## **Streaming event model**

Recommended named SSE events:

* request.started  
* assistant.started  
* token.delta  
* tool.started  
* tool.finished  
* assistant.completed  
* assistant.failed  
* session.updated  
* request.cancelled  
* request.completed  
* heartbeat

## **Error contract**

Suggested HTTP / stream error codes:

* HERMES\_UNAVAILABLE  
* PROFILE\_NOT\_FOUND  
* SESSION\_NOT\_FOUND  
* INVALID\_REQUEST  
* REQUEST\_BUSY  
* STREAM\_NOT\_FOUND  
* INTERNAL\_ERROR

## **Logging requirement**

Logging is a requirement, not optional.

### **Log layers**

1. Mac app logs  
* app launch  
* bridge connect/disconnect  
* session open/create  
* message send  
* stream start/complete/cancel  
* visible UI errors  
2. Bridge logs  
* every API request  
* request\_id/session\_id/agent\_id mapping  
* Hermes subprocess start/exit  
* stream lifecycle  
* cancellations  
* normalized failures  
3. Hermes execution metadata  
* profile used  
* session reference used  
* completion/failure status  
* tool activity when available  
4. Durable audit metadata  
* timestamp  
* request\_id  
* session\_id  
* agent\_id  
* event\_type  
* status  
* duration\_ms

### **Logging format**

Use structured JSON logs.

Example:

{  
  "ts": "2026-06-01T19:15:04Z",  
  "level": "info",  
  "service": "hermes-bridge",  
  "event": "chat\_request\_started",  
  "request\_id": "req\_123",  
  "session\_id": "sess\_1",  
  "agent\_id": "callie"  
}

### **Suggested log locations**

* \~/Library/Logs/HermesMac/app.log  
* \~/Library/Logs/HermesMac/bridge.log  
* \~/Library/Application Support/HermesMac/events.jsonl

### **Privacy-minded default**

* always log metadata and lifecycle events  
* make full prompt/response body logging configurable  
* do not persist token-by-token deltas by default  
* persist final assistant/user messages only if enabled or explicitly desired

## **Current recommendation**

Best v1 path:

* SwiftUI native Mac app  
* thin UI shell  
* local FastAPI bridge  
* Hermes subprocess-backed execution  
* JSON \+ SSE API  
* structured logging from day one

## **Next logical docs**

Possible follow-up notes:

* FastAPI route/schema draft  
* SwiftUI client-side model layer  
* SQLite schema for session and request metadata

