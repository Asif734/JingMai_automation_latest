# JD Jingmai customer-service automation

Flutter desktop UI plus a native Swift/macOS Accessibility adapter for JD Jingmai. It detects `com.jd.jdmddwb`, requests Accessibility access, monitors the selected conversation, fingerprints visible messages, queues captures, stores them in SQLite, and sends guarded replies only after verifying the active customer.

## Run

Prerequisites: Flutter stable with macOS desktop enabled and the full Xcode app selected (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`).

```sh
flutter pub get
flutter run -d macos
```

## Standalone Apple Silicon release

Run `zsh tools/build_standalone_macos.sh` on the build Mac (Flutter/Xcode and
Homebrew FFmpeg/FFprobe are needed only for packaging). This produces
`build/standalone-prompt-release/JD Automation Standalone.zip` and a separate
`JD Automation Standalone.app`, version 0.1.5+6, with bundle ID
`com.grozziie.jdAutomation.standalone`. The existing release app is not replaced.

The single app contains the complete knowledge dataset (cards, Markdown,
catalogs, indexes, source documents, and image/video/audio assets), Codex workspace
and schemas, FFmpeg/FFprobe, their non-system libraries and third-party notices,
and a build-time snapshot of the current `data/` directory including customer
histories, SQLite queue state, customer media, diagnostic logs, and Codex
sessions. Credentials and environment files remain excluded. This package
targets Apple Silicon and macOS 15 or newer. Dataset and initial-data paths,
byte sizes, and verified SHA-256 hashes are recorded in the
bundled `jd_runtime/package_manifest.json`. Only Finder `.DS_Store` metadata
is omitted; symbolic links are rejected rather than shipped as external dependencies.

`zsh tools/build_review_macos.sh` produces the matching 0.1.5+6 Review app under
`build/review-prompt-release/Build/Products/Release/`, using the project's
existing dataset and customer data. Both build scripts leave older copies intact.

On the receiving Mac, unzip it, move the app to Applications, and grant its own
Accessibility/Screen Recording permissions (Speech Recognition for video
transcription). JD Jingmai and an authenticated Codex CLI must already be
installed. Finder launches automatically detect Codex in the official
`~/.local/bin` location, Homebrew, npm/NVM, or the matching VS Code extension;
`CODEX_EXECUTABLE` remains an explicit operator override.

On first launch, the bundled data snapshot is copied to
`~/Library/Application Support/com.grozziie.jdAutomation.standalone/data`.
An existing nonempty standalone data directory is never overwritten.
Do not run both app variants against the same JD conversations simultaneously.
To inspect an installation without starting capture or opening customer data,
run its executable with `JD_INSTALLATION_CHECK=1`; it reports the resolved
resource/data paths and checks that the bundled media tools launch.

## Local Qwen second inspection

The current Review/Codex flow keeps the existing first-pass keyword/Apple
retrieval. Only a second knowledge inspection uses
`Qwen3-Embedding-0.6B-Q8_0`: independent semantic retrieval across all eligible
customer-KB records, combined with lexical results by rank fusion. English and
Chinese questions are preserved. Model/category checks still apply; developer
notes and customer histories are not indexed.

One-time setup on the Review Mac:

```sh
brew install llama.cpp
zsh tools/download_qwen_embeddings.sh
```

This downloads the official, revision-pinned 639 MB GGUF directly from Hugging
Face and verifies its SHA-256. The app starts its own loopback-only native
embedding process; no separate model service or Python runtime is required.
`JD_LLAMA_SERVER` and `JD_QWEN_MODEL_PATH` can specify explicit native-runtime
and model paths. The default weights and derived index live in
`data/qwen_embeddings/`, outside the app bundle. For Standalone, pass its
Application Support `data/qwen_embeddings` path to the download script.

Preparation runs in the background and persists knowledge-only vectors.
The initial full index takes longer than subsequent queries; prepare it before
enabling production automation with this retrieval-only check:

```sh
flutter test --no-pub --dart-define=JD_QWEN_LIVE_TEST=true test/qwen_semantic_live_test.dart --reporter expanded
```

It does not open JD or send messages. A missing model, incomplete index,
invalid embedding, or native timeout is a retriable retrieval failure, not
permission to claim that two searches found no answer or to transfer a chat.
The standalone packager includes the small native runtime/libraries but excludes
downloaded weights and embedding caches from its initial-data snapshot.

### Evidence selection and answer policy

Queries now keep the current request and only necessary follow-up context.
Second-pass fusion preserves a candidate's best rank with bounded agreement,
rather than letting repeated query variants bury a strong single-engine hit.
Before applying the evidence limit, selection deduplicates source paragraphs,
expands operation-relevant sections of retrieved KB sources, and checks coverage
of the requested operations. Explicit mixed-document section headings override
incorrect inherited product-family labels; no sales-model/structure mapping is
invented. Applicable universal safety procedures are reserved independently of
search rank.

A risk label alone is neither missing knowledge nor a transfer instruction.
Hypothetical safety questions receive the supplied conditional safety guidance;
reported active incidents retain that guidance in the actual handoff notice.
Supported troubleshooting may state a conditional repair boundary without
immediately transferring the customer. Missing answers still require a fresh
second inspection, but automatic knowledge-exhaustion handoff is restricted to
unresolved technical problems. Sales, recommendations, specifications and other
nontechnical questions stay in the chat with a supported answer, precise
limitation or useful clarification. Explicit-transfer, refund and active-safety
policies remain separate. Exact-model lifecycle list rows are supplied alongside
specification tables; Current/Legacy/Discontinued never proves live stock.
Stable reply rules live once in `codex_workspace/AGENTS.md`; requests add only
short turn-specific instructions. General no-answer cases ask one useful new
clarification rather than transferring or repeating a holding promise.

Generation-only quality checks use synthetic customers and temporary histories;
they never open JD, send replies, or transfer conversations. They use the
configured Codex account and are opt-in:

```sh
flutter test --no-pub --dart-define=JD_ANSWER_QUALITY_LIVE=true test/answer_quality_live_test.dart --reporter expanded
```

## RAG backend

The backend loads curated customer-service cards and supporting source chunks. It provides lexical retrieval immediately, optional FAISS vector retrieval using OpenAI embeddings, and structured Simplified-Chinese reply drafts. Desktop delivery remains guarded by exact JD customer verification.

Create the local configuration and start it:

```sh
cp .env.example .env
# Edit .env and add OPENAI_API_KEY plus a private RAG_ADMIN_TOKEN.
docker compose up --build api
curl http://127.0.0.1:8080/health
```

Open `http://127.0.0.1:8080/tester` for the lightweight browser test interface. It keeps the last 20 test messages in browser storage and supplies them to each draft request automatically.

The Flutter conversation dialog now uses the same API. It selects the latest captured incoming/unknown message as `customer_message`, sends up to 20 earlier real messages as context, saves the returned draft in the local capture SQLite database, and displays it in a review-only panel. Configure a non-default backend at build time with `--dart-define=RAG_BACKEND_URL=http://127.0.0.1:PORT`. The Flutter app contains no insert/send reply action.

The tester also accepts customer screenshots, photos, and videos. Images are supplied to the model as visual evidence; videos uploaded through the backend tester are stored but deliberately not treated as analyzed. Uploaded images are limited to 15 MB and videos to 50 MB. Retrieved knowledge records expose only allow-listed local media, and draft attachments are filtered against those retrieved IDs before being returned.

The macOS JD capture path recognizes outlined play controls throughout an incoming media crop, including controls displaced by clipping or adjacent text. Before accepting a screen-classified image, a bounded background check searches JD's recent video cache for a unique decoded-frame match. The comparison isolates one photographic preview, handles JD's stretched portrait cards, and permits only bounded vertical clipping retaining at least 70% of a frame. Different matching clips, flat placeholders, incomplete checks, and time-only shared-cache candidates are rejected. Duplicate copies of the identical MP4 are allowed. Customer identity is independently rechecked through AX after cache work. Cache results and crop dimensions are logged, while image/video cache work stays off the serial AX delivery queue. The app copies a uniquely matched video into that customer's private media directory without opening a viewer. FFmpeg extracts one frame per second, up to 20 frames, plus audio for optional macOS Speech transcription. Those frames are passed to Codex for internal analysis. An unverifiable video is left for capture recovery rather than downgraded to an ordinary image or assigned an unrelated recent clip.

## Customer isolation and offline history replay

Capture, sender labels, chat switching, and send acknowledgements require the same complete customer ID. OCR lookalikes (`1`/`l`), different case, truncated prefixes, missing identities, and conflicting headers do not create aliases. History files are checked against their stored `user_id`; newly verified media must remain inside its owner's media directory. Model session files also carry their exact owner, and older unbound sessions start fresh.

Both variants share an OS automation lock under `~/Library/Application Support/JD Automation Shared/automation.lock`. Close the other variant before starting automation. The lock is held for the controller's lifetime, including while paused, and the OS releases it after process exit or a crash. Expired queued chat-switch/send operations are rejected before UI input.

Incoming images use verified cache originals first. If original matching fails,
an actual sender-bounded attachment rectangle may be retained as a partial
preview after customer, message-clock and unchanged-screenshot checks. White,
grey and black previews are not rejected for lacking contrast. Empty inferred
viewports and ordinary typed bubbles are not image fallbacks; no Save As/menu
actions are used. Partial previews are explicitly labelled for Codex and never
prove a video's unseen contents. Customer + JD timestamp + attachment slot
identifies a preview event, with the file SHA-256 saved separately. Repeated
scans do not create messages; a later original upgrades that exact event while
preserving reply cursors. An identical image at a new timestamp is new work.

An already acquired/queued original video suppresses another preview of that
same customer/timestamp/slot, including flat posters. Media input revisions are
bounded by each reply's frozen incoming clock: later uploads remain queued for
their own replies, rather than discarding an earlier completed answer. The
video-analysis stage persists its report against the exact customer, event,
timestamp, hash and frame fingerprint, with a separate two-minute deadline per
video. After analysis completes or explicitly fails, retrieval and both reply
inspections receive a fresh 100-second budget. Replies use the saved reports,
not another pass through the video frames; ordinary photos remain visual
inputs. Failed analysis is explicitly unavailable, never invented contents or
proof of a missing upload. Retries reuse completed reports and exact failed
attempts; legacy short-prepass failures get one attempt under the new policy.
A new event receives a fresh analysis. A holding
receipt covers only incoming messages sent before it. A genuinely later event
gets its own deadline, with a 50-second holding-message cooldown.

Delivery recovery is independent of capture: while automation is running, a five-second tick revisits durable drafts, generation work, and holding-message jobs. Chat-opening callbacks have a ten-second watchdog and send callbacks an eighteen-second watchdog; these do not cancel OS work. A missing send callback is treated as `send_unconfirmed`, retained for exact outgoing-receipt reconciliation and safe retry, not recorded as sent. Failed attempts retry without a fixed attempt limit. The serial worker releases after queue/refresh errors, skips human-contacting chats, and allows capture scans to join the UI queue between deliveries. Queue updates and acknowledgements are bound to the exact customer, draft creation, pending ID, reply, and incoming-batch boundary, so a late attempt cannot consume a replacement batch.

Native AX reads use a process-wide 0.75-second messaging timeout ([Apple API documentation](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)); traversals also have a four-second budget nested within switch/send deadlines. Timed-out snapshots are discarded entirely. Recovery clears only a recorded insertion with the same full active customer, unchanged text, and AX composer element; operator edits are left alone. The final Send click uses freshly verified customer, composer text, button bounds, JD focus, and a current deadline. These safeguards cannot make an unavailable/frozen JD service, stopped app, missing permissions, or disconnected network deliver a message. Such work stays pending rather than being falsely marked delivered or redirected to another customer.

Local diagnostic events are appended to `data/logs/YYYY-MM-DD-PID.jsonl` for the release app, or the standalone data root's `logs` directory. Filenames use Bangladesh dates; each record includes UTC time, executable, PID, operation, relevant customer IDs, elapsed time, and exact native errors. Every error-banner assignment also writes a `ui.error` entry with the exact displayed text and error type (plus the code/message for `PlatformException`); clearing the banner does not remove its log. Video-download, scan-timeout, and model-capacity errors shown in the diagnostics panel are recorded too, with the underlying exception text. Chat bodies, screenshots, prompts, and reply text are not explicitly attached, but exception text can contain sensitive information. The logs are local customer data and should not be published.

Replay the six existing JSON histories through the real capture event/persistence boundary with a mocked native channel and temporary database:

```sh
JD_REPLAY_DATA_ROOT="$PWD/data" flutter test --no-pub test/customer_isolation_replay_test.dart
JD_REPLAY_DATA_ROOT="$PWD/data" flutter test --no-pub test/delivery_watchdog_test.dart test/serial_delivery_worker_test.dart
dart run tools/customer_lease_check.dart
swiftc macos/Runner/CustomerSafety.swift tools/customer_safety_check.swift -o /tmp/jd-customer-safety-check
JD_REPLAY_PROJECT="$PWD" /tmp/jd-customer-safety-check
```

The replay uses up to 80 recent incoming messages from each requested history, 600 shuffled duplicate events, all 30 wrong-customer permutations, focus changes before simulated sends, ID lookalikes, foreign media, and corrupted file ownership. Delivery tests add lost open/send callbacks, late wrong-ID responses, repeated failures, independent retry ticks, storage errors, restart recovery, exact-receipt reconciliation, and replacement-batch guards. They cannot call a live JD window or a model. The Swift check additionally compares the actual Windows/M880 frames from the reported incident when `JD_REPLAY_PROJECT` is set and checks composer ownership and nested AX budget recovery. These tests validate software boundaries; live JD layout/permission compatibility still needs a supervised smoke check after installing the changed build.

Only a customer's second explicit transfer request within ten minutes starts an automatic JD sub-account transfer. The native adapter verifies the exact active customer, opens `快捷转接`, expands `默认咨询组` once, reads account names with Apple Vision, and independently checks green/turquoise status badges. JD Automation fairly rotates among confirmed active accounts, sends a concise transfer acknowledgement, reopens the dialog, revalidates the target, and clicks only that row's explicit blue `转接` action. Red/offline accounts and `备注原因` are never clicked. Transfer attempts are durably logged; successful, transferring, and unconfirmed clicks are never retried automatically. The sidebar shows transfer records only and provides no manual human-review controls.

Local Codex drafts use low reasoning effort and low verbosity, ignore unrelated user-level Codex plugin configuration, and run at most 20 customer workers concurrently. Each customer keeps one frozen active batch: later messages wait for the current reply and are processed afterward. New evidence is collected for 2.5 seconds before a batch starts. Ready replies can be sent while other customers are still generating. If no real reply is sent for a waiting customer within 20 seconds, the app sends one randomly selected short holding message in the customer's language while Codex continues working. Any real reply cancels that holding deadline and gives remaining newer work a fresh 20-second window. Invalid output and process errors remain pending for retry.

Failed-send icon detection reuses the OCR screenshot on a separate, throttled utility queue; incoming OCR never waits for that pixel scan. Only detected candidates emit a background event. Detection requires a white exclamation mark inside the red circle next to a blue outgoing bubble and supports normal/Retina display scales, multiline replies, and JD's watermark. An existing-icon click is allowed only while incoming-signal scans, unread recovery, fallback deadlines, drafting, capture, delivery, and transfer operations are idle. A previous turn's holding reply cannot cancel a new incoming-message deadline; uncertain sends are not treated as replies. Retry never activates JD or switches customers; JD must already be frontmost. The click re-verifies the exact customer, empty composer, unchanged bubble, icon position, and window ownership. Repeated failures use a 15/30/60/120/300-second cooldown. No website connectivity gate, regenerated answer, or duplicate typing is added. Normal Send remains unchanged. A draft with an uncertain send confirmation is reconciled only when subsequent OCR finds the exact recent outgoing reply with JD's read/unread receipt; this advances its frozen-batch cursor without consuming later unanswered questions or recording a duplicate reply. Icon disappearance alone is not treated as delivery.

The reply service represents the JD store only. Retrieval removes other-marketplace material before it reaches Codex, media analysis stays internal, and transferred conversations answer the most recent unresolved customer request before considering a generic welcome.
JD remains an internal service boundary rather than sales wording. Ordinary product and technical replies do not push JD purchasing or append order reminders unless the customer asks about buying, stock, an order, or an exact SKU.

Local Codex replies use the JD-only `格志京东客服知识库-2026-10-04` directory by default, including its app-specific `product_model_feature_catalog_kb.md`. Set `JD_KNOWLEDGE_DIR` to a different directory to override it. Retrieval reads active RAG cards, source chunks, and root-level customer knowledge Markdown; the package's source evidence and READMEs are excluded. The app checks these files for changes before each retrieval and reloads them when needed. On macOS it reranks up to 35 lexical candidates with sentence embeddings made from the loaded text; if embedding is unavailable or exceeds 1.5 seconds, lexical results are used. Requests for a product model list load the catalog and ask Codex to list the full Current category before asking about preferences. Questions about a named model's features also load the catalog and pass matching model rows as primary evidence, including grouped paper-width rows. Keep the curated RAG cards, source chunks, and catalog consistent when editing the raw Markdown knowledge; file reload does not regenerate those authored records.

Technical follow-ups retain a wider conversation window and up to eight recent customer turns so a short complaint does not lose the model, operating system, or original problem. Technical retrieval considers up to 35 candidates and passes up to 20 matching records. Codex must inspect all supplied evidence, must not ask customers for the store's own product link, and may use safe general technical knowledge after local evidence. An unresolved technical result triggers one fresh second investigation before review. Review acknowledgements preserve the details already collected and avoid scripted transfer language.

`codex_workspace/AGENTS.md` contains only the small global output and trust contract. Dart selects an exclusive reply route before generation (`technical_support`, product features/list/recommendation, refund review, requested senior service, or general support), and only the matching route instructions and data are added to that request.

The macOS `.app` does not embed the JD knowledge directory. When installing it outside this project, deploy `格志京东客服知识库-2026-10-04` alongside it and set `JD_KNOWLEDGE_DIR` to its absolute path. The catalog file must be present in that directory.

Media API:

```text
POST /v1/media/upload       multipart customer image/video upload
GET  /v1/media?query=M880   search approved knowledge media
GET  /v1/media/{media_id}   display a known media object
```

The backend inventories every image/video below the knowledge directory into a governed media
catalogue. Existing card-linked assets start verified and customer-sendable; newly discovered
files remain quarantined until a supervisor supplies the correct product model, view, purpose,
and caption. Open `http://127.0.0.1:8080/media-review`, enter `RAG_ADMIN_TOKEN`, review the
thumbnail and metadata, then enable both **Verified** and **Send allowed**. The review API is:

```text
GET /v1/media-catalog                 list/search assets (admin token required)
GET /v1/media-catalog/{id}/preview    preview quarantined assets (admin token required)
PUT /v1/media-catalog/{id}            update and approve metadata (admin token required)
```

Outbound search requires an exact model and returns only verified, customer-sendable assets.
If no approved asset matches the requested model and view, the draft creates a human-review
ticket instead of substituting another product. When a verified match exists, the backend adds
up to three deterministic attachments even if the language model omits attachment IDs.

For media requests, the LLM produces a typed search plan (model, media kind, and requested view). The backend translates that plan into a read-only parameterized SQLite query. Raw model-generated SQL is never executed. Recent customer turns are included when resolving short follow-ups such as `both`, `M880`, or `M880UT`.

An outbound draft can contain attachment suggestions:

```json
{
  "reply": "我把对应图片发您参考。",
  "attachments": [
    {"media_id": "kb_...", "kind": "image", "caption": "图片说明"}
  ],
  "auto_send_allowed": false
}
```

The knowledge directory is mounted read-only and the generated FAISS/SQLite metadata is kept in the `rag-data` Docker volume. Build the vector index once (and again whenever the knowledge files change):

```sh
docker compose exec api python -m app.build_index
```

Lexical retrieval works even before that command. Try it with:

```sh
curl -s http://127.0.0.1:8080/v1/retrieve \
  -H 'Content-Type: application/json' \
  -d '{"query":"TD630G 在 Mac 上怎么无线打印？","product":{"model":"TD630G"}}'
```

Generate a human-reviewed draft:

```sh
curl -s http://127.0.0.1:8080/v1/replies/draft \
  -H 'Content-Type: application/json' \
  -d '{"conversation_id":"demo","customer_message":"TD630G 在 Mac 上怎么无线打印？","messages":[]}'
```

Inspect recent draft history (customer data, so the admin token is required):

```sh
curl -s 'http://127.0.0.1:8080/v1/history?limit=5' \
  -H "X-Admin-Token: $RAG_ADMIN_TOKEN"
```

Filter by conversation:

```sh
curl -s 'http://127.0.0.1:8080/v1/history?limit=20&conversation_id=demo' \
  -H "X-Admin-Token: $RAG_ADMIN_TOKEN"
```

The alternative HTTP rebuild route requires `X-Admin-Token`; the CLI above is simpler. Docker must remain running only while the Flutter app needs retrieval or drafting. Message capture and its local SQLite database remain inside the macOS app and do not depend on Docker.

For local backend tests without Docker:

```sh
python3 -m venv .venv-rag
source .venv-rag/bin/activate
pip install -r backend/requirements-dev.txt
PYTHONPATH=backend pytest backend/tests
```

## Accessibility setup and AX mapping

The distinctly named review media hotfix is created with `zsh tools/build_review_macos.sh` and saved at `build/review-media-hotfix/Build/Products/Release/JD Automation Review.app` (version `0.1.4`, build `5`). It includes the `0.1.3` customer-header fix and the image-to-video cache cross-check. It explicitly disables the standalone define, uses the project's existing `data/`, and uses bundle ID `com.grozziie.jdAutomation.review`. This avoids inheriting a previous standalone Flutter configuration. The complete bundle is signed and verified; the previous running review, release, and standalone binaries are not replaced. Close the previous copy before opening the hotfix.

The October 13 header hotfix distinguishes the customer label aligned above the active chat's quick-transfer control from the separately right-aligned shop label. Selection is scoped to the composer's chat split and does not depend on the requested ID, a name blacklist, or prefix matching. Missing, truncated, or conflicting customer-slot evidence still blocks a send. Accessibility diagnostics print the resolved `activeCustomerId`; failed chat switches record the observed customer too. The native regression checks include the exact live JD 10.4.5.600 header geometry, all six customers, wrong-ID comparisons, duplicate/conflicting/truncated labels, missing control anchors, shop-only headers, and moved/scaled windows.

Authorize this exact copy in System Settings. Permissions are read again when returning to the app and every two seconds while not granted; polling never prompts or starts automation. The screen and local status logs identify the actual bundle path, bundle ID, and permission result. Ad-hoc signing is the default and its designated requirement changes when code changes, so future rebuilt binaries may need renewed authorization. For stable signing, supply an installed certificate via `JD_REVIEW_SIGN_IDENTITY`; no privacy permissions are reset or granted by the build script.

1. Start JD Jingmai and log in.
2. In this app, click **Request Accessibility access**.
3. In **System Settings → Privacy & Security → Accessibility**, enable the built `.app` (or the Terminal/IDE launching `flutter run`). Restart the app after changing permission if macOS does not refresh it.
4. Select a real JD conversation, click **Inspect AX tree**, and save the displayed output.
5. Validate which reported paths correspond to the sidebar row, unread marker, customer identity, message list, and composer before tightening selectors.
6. Click **Start capture** only after the tree is visible.

The native adapter targets the installed JD Jingmai bundle `com.jd.jdmddwb` and the `咚咚融合工作台` reception window.

## Current capture behavior and limitations

- Polls at 700 ms so capture work stays independent of future AI work.
- Uses selected `AXRow`/`AXCell` plus structural scroll-area candidates. It does **not** assume Chinese or English element labels.
- Uses native AX identifiers when exposed; otherwise SHA-256 fingerprints include conversation, content, geometry, and AX path.
- SQLite uniqueness is a second dedupe boundary. `messages_recent` supports efficient last-20 retrieval.
- Direction is inferred from message position relative to the message container; it remains `unknown` when geometry is absent.
- Opening unread rows requires a verified JD conversation row and unread marker. Blindly pressing a guessed row would violate conversation safety.
- Customer IDs and message timestamps are saved when exposed by a validated mapping; the generic discovery pass cannot invent them.

If the AX dump lacks customer identity, message text, unread state, or actionable conversation rows, record precisely those missing attributes first. Clipboard or targeted vision should be considered only for the missing fields.

For a minimal permission probe independent of Flutter:

```sh
clang -framework ApplicationServices tools/ax_probe.c -o /tmp/jingmai_ax_probe
/tmp/jingmai_ax_probe <jingmai-pid>
```

If the calling process is not Accessibility-trusted, macOS returns `AXUnknown` and no child tree. Grant Accessibility permission before mapping JD unread markers, customer identity, message containers, composer attributes, or safe row actions.

## Safety boundary

Windows can later implement the same Dart `CaptureAdapter` with UI Automation. Future sending must be a separate adapter and enforce:

`expected conversation → open chat → verify identity → insert → verify again → send`

The backend never controls desktop UI, and this MVP exposes no send capability.
