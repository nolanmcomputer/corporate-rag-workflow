## Self-Hosted Corporate Knowledge Base

This project deploys two independent Docker Compose stacks for a self-hosted corporate RAG workflow:

**Unstructured** for document partitioning, normalization, metadata preservation, and chunking.

**AnythingLLM** for document ingestion, CPU-based embeddings, vector storage/retrieval, workspace management, and integration with the existing OpenAI-compatible generation endpoint.

Both stacks attach to an existing external Docker network and are scoped to the corporate subtree of the host knowledge vault.

The implementation is intended to be dropped into the supplied target environment and started with:

`docker compose up -d`

for each stack independently.

## Architecture

```
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
                         │              │
                         │ Workspace/API│
                         │ Native CPU   │
                         │ embeddings   │
                         │ LanceDB      │
                         └──────┬───────┘
                                │
                                │ read-only
                                ▼
                      /vault/corporate
                     ┌───────────────────┐
                     │ raw/              │
                     │ processed/        │
                     └───────┬───────────┘
                             ▲
                             │ validated
                             │ chunked JSON
                             │
                      ┌──────┴───────┐
                      │ preprocess.sh│
                      │  host-side   │
                      │   wrapper    │
                      └──────┬───────┘
                             │
                             │ HTTP POST
                             │ selected raw file
                             ▼
                    ┌──────────────────┐
                    │  Unstructured    │
                    │      API         │
                    │                  │
                    │ partitioning     │
                    │ by-title chunking│
                    │ metadata output  │
                    └──────────────────┘
                             │
                             │ /vault/corporate
                             │ read-write bind mount
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

The Unstructured API is stateless in this deployment. `preprocess.sh` is the
host-side orchestration wrapper: it reads a selected file from
`${VAULT_HOST_PATH}/raw`, submits it to the local Unstructured API, validates
the returned chunked JSON, and writes the result to
`${VAULT_HOST_PATH}/processed`.

AnythingLLM reads the corporate vault through a read-only bind mount, while
Unstructured is granted read-write access to the same scoped
`/vault/corporate` subtree. Both containers attach to the existing external
Docker network supplied by `${SHARED_NETWORK_NAME}`.

**The generative model and embedding model are intentionally separate.**

The existing GPU-backed OpenAI-compatible model is used *only* for completion/generation. AnythingLLM uses its native lightweight MiniLM embedding model on CPU so embedding workloads do not consume GPU memory intended for the supplied large model.

## Target Environment Assumptions

The deployment assumes the environment specified in the assessment already provides:

- Windows 11 with WSL2 and Docker Desktop

- Ubuntu 26.04 LTS guest environment

- 64GB system RAM

- NVIDIA RTX 5090 with 32GB VRAM

- An existing external Docker network

- An existing OpenAI-compatible generation service at: **http://host.docker.internal:8000/v1**

- Existing generation model already consumes effectively all available GPU VRAM

- An existing host knowledge vault containing:

	```
	/vault/
	├── corporate/
	├── shared/
	├── tickets/
	├── learning/
	└── skills/
	```

Only the *corporate* subtree is made available to these stacks.

The supplied generation service was not present in the local development environment, so local verification covered configuration and connectivity up to that external dependency. Embedding and semantic retrieval were tested independently and successfully without the generation endpoint.

## Repository / Deployment Layout

The two stacks are independent:

```
~/unstructured-stack/
├── docker-compose.yml
├── .env.example
├── preprocess.sh
└── data/

```

```
~/anythingllm-stack/
├── docker-compose.yml
├── .env.example
├── data/
└─────AnythingLLM runtime state
```

**Local .env files are intentionally excluded from source control.**

The host corporate vault uses:

```
/vault/corporate/
├── raw/
└── processed/
```

In the local assessment environment the actual host path is supplied through `VAULT_HOST_PATH`; neither Compose file hardcodes the host vault location.

### Unstructured `data/` Directory

The Unstructured API is stateless in this deployment, so it does not require a
persistent application-state volume. Persistent preprocessing artifacts are
stored in the externally supplied `${VAULT_HOST_PATH}` corporate vault.

The `~/unstructured-stack/data/` directory is retained to match the requested
stack layout and may be used as a local test fixture by pointing
`VAULT_HOST_PATH` at it during development.

## Shared Docker Network

Both stacks attach to the same pre-existing external Docker network.

For local testing I created:

`docker network create situate-ai`

The *actual* network name is supplied through:

`SHARED_NETWORK_NAME`

and the Compose files use:

```
networks:

 shared:
  
  external: true
    
  name: ${SHARED_NETWORK_NAME}
```

Neither stack owns or creates the network.

## Unstructured Stack

Configuration Example `.env.example`:

```
VAULT_HOST_PATH=/absolute/path/to/vault/corporate
UNSTRUCTURED_PORT=8001
SHARED_NETWORK_NAME=existing-network-name
```

The corporate subtree is mounted read/write:

```
volumes:
  - "${VAULT_HOST_PATH}:/vault/corporate"
```

The parent /vault directory is never mounted.

This prevents the container from accessing:

```
/vault/shared
/vault/tickets
/vault/learning
/vault/skills
```

### Deployment

```
cd ~/unstructured-stack
cp .env.example .env
```

**Edit .env for the target host.**

```
docker compose up -d
docker compose ps
```

API reachability can be checked with:

`curl -i http://localhost:8001/general/v0/general`

A GET request should return:

`405 Method Not Allowed: Only POST requests are supported.`

This confirms that the partition endpoint is reachable.

## Preprocessing Workflow

Raw source documents are placed in:

`/vault/corporate/raw/`

Processed output is written to:

`/vault/corporate/processed/`

A repeatable preprocessing command is provided:

```
cd ~/unstructured-stack
./preprocess.sh <filename>
```

Example:

`./preprocess.sh larger-test.pdf`

Input:

`/vault/corporate/raw/larger-test.pdf`

Output:

`/vault/corporate/processed/larger-test.chunks.json`

`preprocess.sh` accepts one filename beneath `${VAULT_HOST_PATH}/raw`,
submits it to the local Unstructured API, applies the configured chunking
policy, validates the returned JSON, and atomically writes the result beneath
`${VAULT_HOST_PATH}/processed`.

The script processes only the explicitly requested document and does not
recursively scan the vault.

## Chunking Strategy

The preprocessing pipeline uses title-aware chunking:

- chunking_strategy=by_title

- max_characters=1200

- new_after_n_chars=900

- combine_under_n_chars=250

- overlap=100

- overlap_all=false

- multipage_sections=false

- include_orig_elements=true

### Rationale

`by_title` was selected to prefer detected semantic/section boundaries over arbitrary fixed-length splitting.

A hard maximum of 1,200 characters prevents excessively large retrieval units, while the 900-character soft boundary encourages chunks to close before reaching that limit.

Small sections below 250 characters may be combined to avoid producing unnecessarily fragmented retrieval units.

Overlap is limited to 100 characters and is not applied to every chunk. This avoids unnecessary duplication while still providing continuity where oversized elements must be split.

`include_orig_elements=true` preserves the original Unstructured elements that contributed to each combined chunk.

Generated `CompositeElement` chunks retain source filename, page number,
file type, and the contributing original elements through
`include_orig_elements=true`.

### Verification

A multi-section Project Bingo PDF of several thousand characters was used to verify that the policy produces multiple chunks rather than a single document element.

Maximum generated chunk size:

```
jq '[.[].text | length] | max' \
"${VAULT_HOST_PATH}/processed/larger-test.chunks.json"
```

The maximum was verified not to exceed the configured 1,200-character hard limit.

## Preprocessing Format Tests

The Unstructured stack was exercised against:

```
PDF
DOCX
PPTX
HTML
```

PDF, DOCX, and PPTX successfully produced structured element output with source metadata.

### HTML note

During testing with the installed Unstructured build, ordinary HTML passed through the filename= / file-upload path could return an empty element array even though the same valid markup succeeded when processed as HTML text.

In the tested Unstructured version, the v2 HTML parser expected document-oriented markup such as a Document body / Page structure.

A structured HTML test case succeeded under both tested parser paths.

This behavior is documented here rather than hidden because it is version/parser-specific and should be accounted for if arbitrary web HTML is introduced into the production corpus. A small normalization/text-input fallback is the appropriate next hardening step if arbitrary HTML ingestion is required.

## AnythingLLM Stack

Configuration

Representative `.env.example` values:

```
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

Signing secrets are generated using:

`openssl rand -hex 32`

Actual secrets are stored only in `.env`.

## AnythingLLM Storage and Vault Access

AnythingLLM application state is persisted to:

`~/anythingllm-stack/data/`

which is mounted as:

`/app/server/storage`

This preserves:

- application configuration

- workspaces

- SQLite state

- LanceDB data

- embedded documents / vector state

Persistence was verified by creating the Corporate Test workspace, running:

```
docker compose down
docker compose up -d
```

and confirming that the workspace remained present.

The corporate vault is mounted separately and read-only:

`"${VAULT_HOST_PATH}:/vault/corporate:ro"`

Read access was verified by inspecting processed documents from inside the AnythingLLM container.

## Generation Provider

Generation is configured through AnythingLLM's Generic OpenAI provider:

```
LLM_PROVIDER=generic-openai
GENERIC_OPEN_AI_BASE_PATH=http://host.docker.internal:8000/v1
```

The target model name is supplied through:

`GENERIC_OPEN_AI_MODEL_PREF`

and is therefore not hardcoded into Compose.

`host.docker.internal` is explicitly mapped using Docker's host-gateway mechanism so the AnythingLLM container can address the host-provided service.

The supplied large model was not recreated locally because the assessment defines it as an existing target-environment dependency.

## Embeddings

Embeddings are deliberately independent from the generation endpoint:

```
EMBEDDING_ENGINE=native
EMBEDDING_MODEL_PREF=Xenova/all-MiniLM-L6-v2
```

The embedding workload therefore runs locally on CPU.

The supplied GPU-backed OpenAI-compatible model is not used for embeddings. No external embedding service is configured. Document preprocessing, embedding, vector storage, and retrieval remain local to the host.

Vector storage uses:

`VECTOR_DB=lancedb`

This keeps the deployment self-contained and avoids introducing an additional vector-database service.

## Workspace and Semantic Retrieval

A persistent AnythingLLM workspace named:

`Corporate Test`

with slug:

`corporate-test`

was used for RAG verification.

A small Project Bingo document containing:

> Project Bingo begins on September 2.
> Project Manager: Bob Doe.

was embedded using the native MiniLM provider.

Semantic retrieval was then tested independently of the missing generation LLM.

Example query:

> Who is responsible for Project Bingo?

The highest-ranked retrieved content contained:

> Project Manager: Bob Doe.

This demonstrates semantic matching rather than exact string matching: the query uses "responsible for" while the source uses "Project Manager."

Vector retrieval succeeded while the external generation service at `port 8000` was unavailable, independently demonstrating:

Native CPU embedding  -> working

LanceDB storage       -> working

Semantic retrieval    -> working

Generation dependency -> separate

### Workspace Setup

Create an AnythingLLM workspace named:

- Name: `Corporate Test`
- Slug: `corporate-test`

A Developer API key can then be generated from the AnythingLLM settings.

To upload a processed document and associate it with the workspace:

```
curl -sS -X POST \
  http://localhost:3001/api/v1/document/upload \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}" \
  -F "file=@/path/to/vault/corporate/processed/project-bingo.md" \
  -F "addToWorkspaces=corporate-test" | jq .
```

### Semantic Retrieval Test

```
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

## Developer API

AnythingLLM's Developer API is enabled for internal integration.

An API key can be generated through the AnythingLLM Developer API settings page.

Authentication can be verified with:

```
curl -sS \
  http://localhost:3001/api/v1/auth \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}"
```

Expected result:

```
{
  "authenticated": true
}
```

Semantic vector search was tested using:

`POST /api/v1/workspace/corporate-test/vector-search`

with Bearer authentication.

This verifies that a future internal service can reach an authenticated workspace-facing API programmatically.

The intended production flow is:

	Internal service
	      |
	      | authenticated HTTP
	      v
	AnythingLLM workspace
	      |
	      +--> native embedding / LanceDB retrieval
	      |
	      +--> supplied OpenAI-compatible generation endpoint

### Workspace Query API
	      
For services attached to `${SHARED_NETWORK_NAME}`, the workspace API is
reachable through Docker DNS rather than the host-published port:

```text
http://anythingllm:3001
```

The `Corporate Test` workspace can be queried through:

`POST http://anythingllm:3001/api/v1/workspace/corporate-test/chat`

Using the Developer API key as a Bearer token.

### MCP

An MCP endpoint was not used or verified as part of this implementation. The tested programmatic integration path is the authenticated AnythingLLM HTTP Developer API described above.
	      
## AnythingLLM Direct-Ingestion Tests

A separate workspace was created for direct-ingestion testing:

`direct-ingestion-test`

The objective was to determine which formats AnythingLLM can consume usefully without first passing through Unstructured.

Testing should be judged by all three stages:

- upload accepted

- embedding succeeds

- extracted content is semantically retrievable

### Test Results

| Format | Upload | Embedded | Semantic Retrieval | Recommendation |
|---|---:|---:|---:|---|
| PDF | PASS | PASS | PASS | Direct ingestion is supported. Use Unstructured when controlled chunking and explicit page/source metadata are preferred. |
| DOCX | PASS | PASS | PASS | Direct ingestion is supported. Unstructured remains preferable when normalized, metadata-preserving preprocessing is desired. |
| PPTX | PASS | PASS | PASS | Direct ingestion is supported. Unstructured is preferable where slide/page provenance and consistent chunking are important. |
| HTML | PASS* | PASS* | PASS* | Direct ingestion generally works, but a minor HTML parsing/extraction limitation was observed during testing. Prefer preprocessing when predictable HTML normalization is required. |

\* HTML uploaded, embedded, and produced retrievable content, but a minor parsing/extraction inconsistency was observed during testing

### Direct-Ingestion Findings

PDF, DOCX, and PPTX were successfully uploaded, embedded, and retrieved directly. HTML was also retrievable but showed a minor parsing inconsistency. Direct ingestion is supported, but the Unstructured path remains preferred where deterministic chunking and provenance preservation are required.

## Deployment

```
Unstructured
cd ~/unstructured-stack
```

```
cp .env.example .env
```

**Edit deployment-specific values.**

```
docker compose up -d
docker compose ps
```

Run preprocessing:

```
./preprocess.sh <filename>
```
AnythingLLM

```
cd ~/anythingllm-stack
cp .env.example .env
```
**Edit deployment-specific values and generate secrets.**

```
docker compose up -d
docker compose ps
```

AnythingLLM UI:

```
http://localhost:3001
```

Unstructured host API:

```
http://localhost:8001/general/v0/general
```

## Health / Verification Checks

Containers

```
cd ~/unstructured-stack
docker compose ps
```

```
cd ~/anythingllm-stack
docker compose ps
```

AnythingLLM should report healthy.

**Shared network**

```
docker network inspect "${SHARED_NETWORK_NAME}" \
  --format '{{range .Containers}}{{println .Name .IPv4Address}}{{end}}'
```

Both containers should be present.

**Inter-container connectivity**

From AnythingLLM:

`docker compose exec anythingllm getent hosts unstructured`

and:

```
docker compose exec anythingllm \
  curl -i http://unstructured:8000/general/v0/general
```

**Vault isolation**

Unstructured should be able to write beneath /vault/corporate.

AnythingLLM should fail:

```
docker compose exec anythingllm \
  touch /vault/corporate/write-test
```

with:
```
Read-only file system
```

## Tested Container Images

The Compose files are pinned to the exact image digests used during
development and verification:

- AnythingLLM: `mintplexlabs/anythingllm@sha256:a5de2ba74bf28dfadeb2e09fab202efbd358c4a7127d040373f2588eea928bea`
- Unstructured API: `downloads.unstructured.io/unstructured-io/unstructured-api@sha256:0df934a22e4e893cf15e7aeaf35c463ecc75937758a83099aefdc13041619a1d`

The installed Unstructured Python package in the tested image was `0.22.18`.

## Verification Checklist

The following were verified during implementation:

- [x] Two independent Docker Compose stacks
- [x] Both start with `docker compose up -d`
- [x] External shared Docker network
- [x] Network name supplied through environment configuration
- [x] Host corporate path supplied through environment configuration
- [x] Neither stack mounts the parent `/vault` directory
- [x] Unstructured receives read/write access to `/vault/corporate`
- [x] AnythingLLM receives read-only access to `/vault/corporate`
- [x] AnythingLLM persistent storage survives container recreation
- [x] PDF preprocessing
- [x] DOCX preprocessing
- [x] PPTX preprocessing
- [x] HTML parser behavior tested and documented
- [x] Repeatable `raw -> processed` preprocessing command
- [x] Explicit title-aware chunking policy
- [x] Maximum chunk size verified
- [x] Source metadata retained
- [x] Original contributing elements retained
- [x] Existing OpenAI-compatible generation endpoint parameterized
- [x] Generation model name externalized
- [x] API credential externalized
- [x] Signing secrets externalized
- [x] CPU-native embedding model configured separately from generation
- [x] LanceDB vector persistence
- [x] Persistent AnythingLLM workspace
- [x] Developer API authentication
- [x] Semantic retrieval verified without generation model
- [x] Inter-container DNS / shared-network communication
- [x] Full stop/start deployment rehearsal
- [x] Direct ingestion tested for PDF, DOCX, PPTX, and HTML
- [x] AnythingLLM internal HTTP API documented
- [x] Container images pinned to tested digests

## Security Notes

The implementation uses the container mount boundary rather than application convention to enforce vault access.

Neither container receives visibility into the parent knowledge vault.

AnythingLLM's access is additionally read-only.

Secrets are not embedded in docker-compose.yml.

Local `.env` files should not be committed.

Local `.env` files and generated AnythingLLM runtime state under `anythingllm-stack/data/`
are excluded from source control. The repository retains only the empty
mount target (via `.gitkeep`).

Production API keys and AnythingLLM signing values should be generated or injected specifically for the target host.

## Known Limitations / Assumptions

The supplied OpenAI-compatible generation service was not available in the development environment. Its address and model are parameterized according to the target specification.
Semantic embedding and vector retrieval were verified independently of the generation dependency.
The tested Unstructured build exhibited differing HTML behavior between normal file-based input and its text/document-oriented parser paths. Structured HTML was successfully processed. Arbitrary HTML ingestion should receive a small normalization/text-input fallback if that behavior remains present in the target image.
The current preprocessing workflow is intentionally explicit rather than a filesystem watcher. Documents are processed one at a time through preprocess.sh, reducing accidental access or ingestion outside the intended corporate source path.
