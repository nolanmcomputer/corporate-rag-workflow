# Self-Hosted Corporate Knowledge Base

This project deploys two independent Docker Compose stacks for a self-hosted corporate RAG workflow:

- **Unstructured** for document partitioning, normalization, metadata preservation, and chunking.
- **AnythingLLM** for document ingestion, CPU-based embeddings, vector storage/retrieval, workspace management, and integration with the existing OpenAI-compatible generation endpoint.

Both stacks attach to an existing external Docker network and are scoped to the corporate subtree of the host knowledge vault. Each stack is intended to start independently with:

`docker compose up -d`

## Architecture

```text
                         Existing target host
                                 │
                    OpenAI-compatible LLM
              http://host.docker.internal:8000/v1
                                 │
                          Generation only
                                 │
                                 ▼
                         ┌──────────────┐
                         │ AnythingLLM  │
                         │ Workspace/API│
                         │ Native CPU   │
                         │ embeddings   │
                         │ LanceDB      │
                         └──────┬───────┘
                                │ read-only
                                ▼
                      /vault/corporate
                     ┌───────────────────┐
                     │ raw/              │
                     │ processed/        │
                     └───────┬───────────┘
                             ▲
                             │ validated chunked JSON
                             │
                      ┌──────┴───────┐
                      │ preprocess.sh│
                      │  host-side   │
                      │   wrapper    │
                      └──────┬───────┘
                             │ HTTP POST
                             ▼
                    ┌──────────────────┐
                    │  Unstructured    │
                    │      API         │
                    │ partitioning     │
                    │ by-title chunking│
                    │ metadata output  │
                    └──────────────────┘
                             │
                             │ /vault/corporate (RW)
                             ▼
                      /vault/corporate

        ───────────────── Shared Docker Network ─────────────────
                     ${SHARED_NETWORK_NAME}

               Unstructured          AnythingLLM
                     │                    │
                     └────────┬───────────┘
                              │
                     container DNS/API access
```

The Unstructured API is stateless in this deployment. `preprocess.sh` reads one selected file from `${VAULT_HOST_PATH}/raw`, submits it to the local Unstructured API, validates the returned chunked JSON, and writes the result to `${VAULT_HOST_PATH}/processed`.

AnythingLLM mounts the same scoped `/vault/corporate` subtree read-only; Unstructured receives read-write access. Both containers attach to the external network supplied by `${SHARED_NETWORK_NAME}`.

**Generation and embeddings are intentionally separate.** The existing GPU-backed OpenAI-compatible model is used only for generation. AnythingLLM uses `Xenova/all-MiniLM-L6-v2` on CPU so embedding workloads do not consume GPU VRAM reserved for the supplied model.

## Target Environment and Layout

The deployment assumes the assessment environment already provides:

- Windows 11 with WSL2 and Docker Desktop
- Ubuntu 26.04 LTS guest environment
- 64 GB system RAM
- NVIDIA RTX 5090 with 32 GB VRAM
- an existing external Docker network
- an OpenAI-compatible generation service at `http://host.docker.internal:8000/v1`
- a generation model that already consumes effectively all available GPU VRAM
- a host knowledge vault containing:

```text
/vault/
├── corporate/
├── shared/
├── tickets/
├── learning/
└── skills/
```

Only the `corporate` subtree is exposed to these stacks.

The supplied generation service was not present in the local development environment. Local verification therefore covered configuration and connectivity up to that dependency, while embedding and semantic retrieval were tested independently.

### Stack Layout

```text
~/unstructured-stack/
├── docker-compose.yml
├── .env.example
├── preprocess.sh
└── data/
```

```text
~/anythingllm-stack/
├── docker-compose.yml
├── .env.example
└── data/          # AnythingLLM runtime state
```

The host corporate vault is expected to contain:

```text
/vault/corporate/
├── raw/
└── processed/
```

Its host path is supplied through `VAULT_HOST_PATH`; neither Compose file hardcodes it.

The Unstructured API does not require persistent application state. `~/unstructured-stack/data/` is retained to match the requested layout and can be used as a local test fixture by pointing `VAULT_HOST_PATH` to it. Persistent preprocessing artifacts remain in the host corporate vault.

### Local Test Vault

The repository includes a small synthetic test fixture under:

```
test-vault/
└── corporate/
    ├── raw/
    └── processed/
```

The files under `test-vault/` contain only synthetic "Project Bingo" data used during local preprocessing, ingestion, and retrieval verification. `test-vault/` is not required in the target deployment. In the supplied target environment, `VAULT_HOST_PATH` should point to the existing corporate vault directory on the host.

## Configuration

### Shared Docker Network

Both stacks use the same pre-existing external Docker network. For local testing I created:

```bash
docker network create situate-ai
```

The actual network name is supplied through `SHARED_NETWORK_NAME`:

```yaml
networks:
  shared:
    external: true
    name: ${SHARED_NETWORK_NAME}
```

Neither stack owns or creates the target network.

### Unstructured

Representative `.env.example` values:

```env
VAULT_HOST_PATH=/absolute/path/to/vault/corporate
UNSTRUCTURED_PORT=8001
SHARED_NETWORK_NAME=existing-network-name
```

The corporate subtree is mounted read-write:

```yaml
volumes:
  - "${VAULT_HOST_PATH}:/vault/corporate"
```

The parent `/vault` directory is never mounted, so `/vault/shared`, `/vault/tickets`, `/vault/learning`, and `/vault/skills` are outside the container's filesystem view.

### AnythingLLM

Representative `.env.example` values:

```env
ANYTHINGLLM_PORT=3001

VAULT_HOST_PATH=/absolute/path/to/vault/corporate
SHARED_NETWORK_NAME=existing-network-name

LLM_PROVIDER=generic-openai
GENERIC_OPEN_AI_BASE_PATH=http://host.docker.internal:8000/v1
GENERIC_OPEN_AI_MODEL_PREF=replace-with-target-model-name
GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT=4096
GENERIC_OPEN_AI_API_KEY=non-empty-placeholder

EMBEDDING_ENGINE=native
EMBEDDING_MODEL_PREF=Xenova/all-MiniLM-L6-v2
VECTOR_DB=lancedb

SIG_KEY=generate-with-openssl-rand-hex-32
SIG_SALT=generate-with-openssl-rand-hex-32
```

Generate signing values with:

```bash
openssl rand -hex 32
```

Actual secrets are stored only in `.env` and are not committed.

## Unstructured Preprocessing

### Workflow

Raw documents are placed in `/vault/corporate/raw/`; processed output is written to `/vault/corporate/processed/`.

Run:

```bash
cd ~/unstructured-stack
./preprocess.sh <filename>
```

Example:

```bash
./preprocess.sh larger-test.pdf
```

Input:

`/vault/corporate/raw/larger-test.pdf`

Output:

`/vault/corporate/processed/larger-test.chunks.json`

`preprocess.sh` processes only the explicitly requested document. It submits the file to the local Unstructured API, applies the chunking policy below, validates that a non-empty JSON array was returned, and atomically writes the result to `processed/`. It does not recursively scan the vault.

### Chunking and Metadata

The preprocessing pipeline uses title-aware chunking:

- `chunking_strategy=by_title`
- `max_characters=1200`
- `new_after_n_chars=900`
- `combine_under_n_chars=250`
- `overlap=100`
- `overlap_all=false`
- `multipage_sections=false`
- `include_orig_elements=true`

`by_title` prefers detected semantic/section boundaries over arbitrary fixed-length splitting. The 1,200-character hard limit prevents oversized retrieval units, while the 900-character soft boundary encourages earlier chunk closure. Sections below 250 characters may be combined to avoid excessive fragmentation. A 100-character overlap is used only when splitting requires it.

Generated `CompositeElement` chunks retain source filename, page number, file type, and contributing original elements through `include_orig_elements=true`.

A multi-section "Project Bingo" PDF was used to verify that the policy produces multiple chunks. The maximum chunk length was checked with:

```bash
jq '[.[].text | length] | max' \
  "${VAULT_HOST_PATH}/processed/larger-test.chunks.json"
```

The result did not exceed the configured 1,200-character hard limit.

### Format Tests

The Unstructured stack was exercised against PDF, DOCX, PPTX, and HTML. PDF, DOCX, and PPTX produced structured output with source metadata.

#### HTML Note

With the tested Unstructured build, ordinary HTML passed through the file-upload path could return an empty element array even though the same valid markup succeeded when processed as HTML text. The v2 HTML parser also expected document-oriented markup such as a `Document` body / `Page` structure; a structured HTML test case succeeded under both tested parser paths.

If arbitrary HTML becomes part of the production corpus, a small normalization/text-input fallback is the recommended hardening step.

## AnythingLLM

### Storage and Vault Access

AnythingLLM application state is persisted in:

`~/anythingllm-stack/data/`

mounted at:

`/app/server/storage`

This preserves application configuration, workspaces, SQLite state, LanceDB data, and embedded-document/vector state. Persistence was verified across `docker compose down` / `docker compose up -d`.

The corporate vault is mounted separately and read-only:

```yaml
- "${VAULT_HOST_PATH}:/vault/corporate:ro"
```

### Generation, Embeddings, and Vector Storage

Generation uses AnythingLLM's Generic OpenAI provider with the target endpoint supplied through `GENERIC_OPEN_AI_BASE_PATH`; the target model name is externalized through `GENERIC_OPEN_AI_MODEL_PREF`.

`host.docker.internal` is mapped through Docker's host-gateway mechanism so the container can reach the host-provided generation service.

Embeddings are local and CPU-based:

```env
EMBEDDING_ENGINE=native
EMBEDDING_MODEL_PREF=Xenova/all-MiniLM-L6-v2
VECTOR_DB=lancedb
```

No external embedding service is configured. Document preprocessing, embedding, vector storage, and retrieval remain local to the host.

### Workspace Setup and Ingestion

Create an AnythingLLM workspace:

- **Name:** `Corporate Test`
- **Slug:** `corporate-test`

This workspace name keeps assessment/test ingestion isolated; production naming can follow the target environment's internal convention.

Generate a Developer API key from AnythingLLM settings and export it as `ANYTHINGLLM_API_KEY`, then verify authentication:

```bash
curl -sS \
  http://localhost:3001/api/v1/auth \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}"
```

Expected:

```json
{
  "authenticated": true
}
```

To upload a processed test document and associate it with the workspace:

```bash
curl -sS -X POST \
  http://localhost:3001/api/v1/document/upload \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}" \
  -F "file=@/path/to/vault/corporate/processed/project-bingo.md" \
  -F "addToWorkspaces=corporate-test" | jq .
```

### Semantic Retrieval

The test document contained:

> Project Bingo begins on September 2.  
> Project Manager: Bob Doe.

The query:

> Who is responsible for Project Bingo?

retrieved content containing:

> Project Manager: Bob Doe.

This verifies semantic matching rather than an exact-string lookup.

The retrieval API can be tested with:

```bash
curl -sS -X POST \
  http://localhost:3001/api/v1/workspace/corporate-test/vector-search \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "Who is responsible for Project Bingo?",
    "topN": 4,
    "scoreThreshold": 0.0
  }' | jq .
```

Vector retrieval succeeded without the external generation service, independently verifying the native CPU embedding path and LanceDB persistence.

### Workspace Query API

For services attached to `${SHARED_NETWORK_NAME}`, AnythingLLM is reachable through Docker DNS at:

`http://anythingllm:3001`

The verified workspace chat endpoint is:

`POST http://anythingllm:3001/api/v1/workspace/corporate-test/chat`

Requests use the Developer API key as a Bearer token. Full generation was not exercised locally because the assessment-supplied OpenAI-compatible service was not present in the development environment.

### MCP

An MCP endpoint was not used or verified. The tested programmatic integration path is the authenticated AnythingLLM HTTP Developer API described above.

### Direct-Ingestion Tests

A separate `direct-ingestion-test` workspace was used to determine which source formats AnythingLLM could upload, embed, and retrieve without Unstructured preprocessing.

| Format | Upload | Embedded | Semantic Retrieval | Recommendation |
|---|---:|---:|---:|---|
| PDF | PASS | PASS | PASS | Direct ingestion supported. Prefer Unstructured when controlled chunking and explicit provenance are required. |
| DOCX | PASS | PASS | PASS | Direct ingestion supported. Prefer Unstructured for normalized, metadata-preserving preprocessing. |
| PPTX | PASS | PASS | PASS | Direct ingestion supported. Prefer Unstructured where slide/page provenance and consistent chunking matter. |
| HTML | PASS* | PASS* | PASS* | Direct ingestion generally works, but a minor parsing/extraction inconsistency was observed. Prefer preprocessing when predictable HTML normalization is required. |

\* HTML uploaded, embedded, and produced retrievable content, but a minor parsing/extraction inconsistency was observed during testing.

Direct ingestion is therefore supported for the tested formats, but the Unstructured path remains preferred where deterministic chunking and provenance preservation are required.

## Deployment

### Unstructured

```bash
cd ~/unstructured-stack
cp .env.example .env
# Edit deployment-specific values. For local testing, `VAULT_HOST_PATH` may point to the included `test-vault/corporate` fixture. In the target environment, set it to the existing corporate vault path instead.
docker compose up -d
docker compose ps
```

Run preprocessing with:

```bash
./preprocess.sh <filename>
```

### AnythingLLM

```bash
cd ~/anythingllm-stack
cp .env.example .env
# Edit deployment-specific values and generate secrets.
docker compose up -d
docker compose ps
```

AnythingLLM UI:

`http://localhost:3001`

Unstructured host API:

`http://localhost:8001/general/v0/general`

## Verification

Load the Unstructured `.env` into the shell before commands that reference deployment variables:

```bash
cd ~/unstructured-stack
source .env
```

### Container State

```bash
cd ~/unstructured-stack
docker compose ps

cd ~/anythingllm-stack
docker compose ps
```

AnythingLLM should report healthy.

### Shared Network and DNS

```bash
docker network inspect "${SHARED_NETWORK_NAME}" \
  --format '{{range .Containers}}{{println .Name .IPv4Address}}{{end}}'
```

Both containers should be present.

From AnythingLLM:

```bash
docker compose exec anythingllm getent hosts unstructured

docker compose exec anythingllm \
  curl -i http://unstructured:8000/general/v0/general
```

A GET to the Unstructured partition endpoint should return `405 Method Not Allowed`, confirming API reachability.

### Vault Isolation

Unstructured should be able to write beneath `/vault/corporate`. AnythingLLM should fail:

```bash
docker compose exec anythingllm \
  touch /vault/corporate/write-test
```

Expected:

```text
Read-only file system
```

### Verification Checklist

- [x] Two independent Docker Compose stacks
- [x] Both start with `docker compose up -d`
- [x] External shared Docker network
- [x] Network and host vault path supplied through environment configuration
- [x] Neither stack mounts the parent `/vault` directory
- [x] Unstructured receives read/write access to `/vault/corporate`
- [x] AnythingLLM receives read-only access to `/vault/corporate`
- [x] AnythingLLM persistent storage survives container recreation
- [x] PDF, DOCX, PPTX, and HTML preprocessing behavior tested
- [x] Repeatable `raw -> processed` preprocessing command
- [x] Explicit title-aware chunking policy and maximum chunk size verified
- [x] Source metadata and original contributing elements retained
- [x] Generation endpoint, model name, API credential, and signing secrets externalized
- [x] CPU-native embedding model configured separately from generation
- [x] LanceDB vector persistence and semantic retrieval verified without generation
- [x] Developer API authentication and internal HTTP API verified
- [x] Direct ingestion tested for PDF, DOCX, PPTX, and HTML
- [x] Inter-container DNS / shared-network communication verified
- [x] Full stop/start deployment rehearsal completed
- [x] Container images pinned to tested digests

## Tested Container Images

The Compose files are pinned to the exact image digests used during development and verification:

- AnythingLLM: `mintplexlabs/anythingllm@sha256:a5de2ba74bf28dfadeb2e09fab202efbd358c4a7127d040373f2588eea928bea`
- Unstructured API: `downloads.unstructured.io/unstructured-io/unstructured-api@sha256:0df934a22e4e893cf15e7aeaf35c463ecc75937758a83099aefdc13041619a1d`

The installed Unstructured Python package in the tested image was `0.22.18`.

## Security Notes

- Filesystem isolation is enforced through container mount boundaries rather than application convention.
- Neither container receives visibility into the parent knowledge vault; AnythingLLM's corporate mount is additionally read-only.
- Secrets are not embedded in `docker-compose.yml`.
- Local `.env` files and generated AnythingLLM runtime state under `anythingllm-stack/data/` are excluded from source control; the repository retains only the empty mount target via `.gitkeep`.
- Production API keys and AnythingLLM signing values should be generated or injected specifically for the target host.

## Known Limitations / Assumptions

- The supplied OpenAI-compatible generation service was not available in the development environment. Its address and model are parameterized according to the target specification; semantic embedding and vector retrieval were verified independently.
- The tested Unstructured build showed differing HTML behavior between ordinary file-upload input and its text/document-oriented parser paths. Structured HTML was successfully processed. Arbitrary HTML should receive a normalization/text-input fallback if this behavior remains present in the target image.
- The preprocessing workflow is intentionally explicit rather than a filesystem watcher. Documents are processed one at a time through `preprocess.sh`, limiting accidental ingestion outside the intended source path.
