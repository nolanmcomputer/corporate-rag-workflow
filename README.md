## Self-Hosted Corporate Knowledge Base##

This project deploys two independent Docker Compose stacks for a self-hosted corporate RAG workflow:

**Unstructured** for document partitioning, normalization, metadata preservation, and chunking.
**AnythingLLM** for document ingestion, CPU-based embeddings, vector storage/retrieval, workspace management, and integration with the existing OpenAI-compatible generation endpoint.

Both stacks attach to an existing external Docker network and are scoped to the corporate subtree of the host knowledge vault.

The implementation is intended to be dropped into the supplied target environment and started with:

docker compose up -d

for each stack independently.

## Architecture
                    Existing target host
                            │
                OpenAI-compatible LLM
          http://host.docker.internal:8000/v1
                            │
                      Generation only
                            │
                            ▼
                      AnythingLLM
                       /       \
                      /         \
          Native CPU embedder   Workspace/API
          all-MiniLM-L6-v2          │
                  │                  │
                  ▼                  │
               LanceDB              │
                  ▲                  │
                  │                  │
         /vault/corporate (RO)      │
                  ▲                  │
                  │                  │
         /vault/corporate (RW)      │
                  │                  │
             Unstructured           │
                  ▲                  │
                  │                  │
         raw/ → processed/          │
                  │                  │
                  └────────┬─────────┘
                           │
                    External Docker
                       network
                  ${SHARED_NETWORK_NAME}

**The generative model and embedding model are intentionally separate.**

The existing GPU-backed OpenAI-compatible model is used only for completion/generation. AnythingLLM uses its native lightweight MiniLM embedding model on CPU so embedding workloads do not consume GPU memory intended for the supplied large model.

## Target Environment Assumptions

The deployment assumes the environment specified in the assessment already provides:

Windows 11 with WSL2 and Docker Desktop
An existing external Docker network
An existing OpenAI-compatible generation service at:

**http://host.docker.internal:8000/v1**

An existing host knowledge vault containing:
/vault/
├── corporate/
├── shared/
├── tickets/
├── learning/
└── skills/

Only the corporate subtree is made available to these stacks.

The supplied generation service was not present in my local development environment, so local verification covered configuration and connectivity up to that external dependency. Embedding and semantic retrieval were tested independently and successfully without the generation endpoint.

## Repository / Deployment Layout

The two stacks are independent:

~/unstructured-stack/
├── docker-compose.yml
├── .env.example
├── preprocess.sh
└── data/

~/anythingllm-stack/
├── docker-compose.yml
├── .env.example
└── data/

**Local .env files are intentionally excluded from source control.**

The host corporate vault uses:

/vault/corporate/
├── raw/
└── processed/

In the local assessment environment the actual host path is supplied through VAULT_HOST_PATH; neither Compose file hardcodes the host vault location.

## Shared Docker Network

Both stacks attach to the same pre-existing external Docker network.

For local testing I created:

docker network create situate-ai

The actual network name is supplied through:

SHARED_NETWORK_NAME

and the Compose files use:

networks:
  shared:
    external: true
    name: ${SHARED_NETWORK_NAME}

Neither stack owns or creates the network.

Verification:

docker network inspect "${SHARED_NETWORK_NAME}"

Both unstructured and anythingllm should appear under Containers.

Container-to-container DNS was also verified from AnythingLLM:

docker compose exec anythingllm getent hosts unstructured

and the Unstructured API was reachable over the shared network.

## Unstructured Stack
Configuration

Example .env.example:

VAULT_HOST_PATH=/absolute/path/to/vault/corporate
UNSTRUCTURED_PORT=8001
SHARED_NETWORK_NAME=existing-network-name

The corporate subtree is mounted read/write:

volumes:
  - "${VAULT_HOST_PATH}:/vault/corporate"

The parent /vault directory is never mounted.

This prevents the container from accessing:

/vault/shared
/vault/tickets
/vault/learning
/vault/skills
Deployment
cd ~/unstructured-stack
cp .env.example .env
**Edit .env for the target host.**

docker compose up -d
docker compose ps

API reachability can be checked with:

curl -i http://localhost:8001/general/v0/general

A GET request should return:

405 Method Not Allowed
Only POST requests are supported.

This confirms that the partition endpoint is reachable.

## Preprocessing Workflow

Raw source documents are placed in:

/vault/corporate/raw/

Processed output is written to:

/vault/corporate/processed/

A repeatable preprocessing command is provided:

cd ~/unstructured-stack
./preprocess.sh <filename>

Example:

./preprocess.sh project-bingo-large.pdf

Input:

/vault/corporate/raw/project-bingo-large.pdf

Output:

/vault/corporate/processed/project-bingo-large.chunks.json

The script:

Loads deployment configuration from .env.
Validates that the requested source file exists inside the corporate raw directory.
Sends the document to the local Unstructured API.
Applies the configured chunking policy.
Validates that the response is a non-empty JSON array.
Writes to a temporary file first.
Atomically moves the successful result into processed/.
Prints a summary of generated chunks.

The script never recursively scans /vault and never receives a path outside the configured corporate subtree.

## Chunking Strategy

The preprocessing pipeline uses title-aware chunking:

chunking_strategy=by_title
max_characters=1200
new_after_n_chars=900
combine_under_n_chars=250
overlap=100
overlap_all=false
multipage_sections=false
include_orig_elements=true
Rationale

by_title was selected to prefer detected semantic/section boundaries over arbitrary fixed-length splitting.

A hard maximum of 1,200 characters prevents excessively large retrieval units, while the 900-character soft boundary encourages chunks to close before reaching that limit.

Small sections below 250 characters may be combined to avoid producing unnecessarily fragmented retrieval units.

Overlap is limited to 100 characters and is not applied to every chunk. This avoids unnecessary duplication while still providing continuity where oversized elements must be split.

include_orig_elements=true preserves the original Unstructured elements that contributed to each combined chunk.

Verification

A multi-section Project Bingo PDF of several thousand characters was used to verify that the policy produces multiple chunks rather than a single document element.

Chunk count:

jq 'length' \
  "${VAULT_HOST_PATH}/processed/project-bingo-large.chunks.json"

Maximum generated chunk size:

jq '[.[].text | length] | max' \
  "${VAULT_HOST_PATH}/processed/project-bingo-large.chunks.json"

The maximum was verified not to exceed the configured 1,200-character hard limit.

Metadata can be inspected with:

jq -r '
  .[] |
  [
    .type,
    (.metadata.filename // "n/a"),
    (.metadata.page_number // "n/a"),
    (.metadata.filetype // "n/a"),
    (.text | length)
  ] |
  @tsv
' "${VAULT_HOST_PATH}/processed/project-bingo-large.chunks.json"
5. Metadata / Provenance

Processed elements retain provenance where available, including:

source filename
page number
file type
element type
original contributing elements

Example structure:

{
  "type": "CompositeElement",
  "text": "Project Bingo begins on September 2...",
  "metadata": {
    "filename": "project-bingo-large.pdf",
    "page_number": 1,
    "filetype": "application/pdf",
    "orig_elements": "..."
  }
}

orig_elements is retained so metadata from the source partition elements remains recoverable even after multiple elements have been combined into a RAG chunk.

## Preprocessing Format Tests

The Unstructured stack was exercised against:

PDF
DOCX
PPTX
HTML

PDF, DOCX, and PPTX successfully produced structured element output with source metadata.

HTML note

During testing with the installed Unstructured build, ordinary HTML passed through the filename= / file-upload path could return an empty element array even though the same valid markup succeeded when processed as HTML text.

The newer HTML parser also expects document-oriented markup such as a Document body / Page structure.

A structured HTML test case succeeded under both tested parser paths.

This behavior is documented here rather than hidden because it is version/parser-specific and should be accounted for if arbitrary web HTML is introduced into the production corpus. A small normalization/text-input fallback is the appropriate next hardening step if arbitrary HTML ingestion is required.

## AnythingLLM Stack
Configuration

Representative .env.example values:

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

Signing secrets are generated using:

openssl rand -hex 32

Actual secrets are stored only in .env.

## AnythingLLM Storage and Vault Access

AnythingLLM application state is persisted to:

~/anythingllm-stack/data/

which is mounted as:

/app/server/storage

This preserves:

application configuration
workspaces
SQLite state
LanceDB data
embedded documents / vector state

Persistence was verified by creating the Corporate Test workspace, running:

docker compose down
docker compose up -d

and confirming that the workspace remained present.

The corporate vault is mounted separately and read-only:

- "${VAULT_HOST_PATH}:/vault/corporate:ro"

Read access was verified by inspecting processed documents from inside the AnythingLLM container.

Write isolation was verified with:

docker compose exec anythingllm \
  touch /vault/corporate/anythingllm-write-test

Expected result:

Read-only file system

This failure is intentional and confirms the required access boundary.

## Generation Provider

Generation is configured through AnythingLLM's Generic OpenAI provider:

LLM_PROVIDER=generic-openai
GENERIC_OPEN_AI_BASE_PATH=http://host.docker.internal:8000/v1

The target model name is supplied through:

GENERIC_OPEN_AI_MODEL_PREF

and is therefore not hardcoded into Compose.

host.docker.internal is explicitly mapped using Docker's host-gateway mechanism so the AnythingLLM container can address the host-provided service.

The supplied large model was not recreated locally because the assessment defines it as an existing target-environment dependency.

## Embeddings

Embeddings are deliberately independent from the generation endpoint:

EMBEDDING_ENGINE=native
EMBEDDING_MODEL_PREF=Xenova/all-MiniLM-L6-v2

The embedding workload therefore runs locally on CPU.

The supplied GPU-backed OpenAI-compatible model is not used for embeddings.

Vector storage uses:

VECTOR_DB=lancedb

This keeps the deployment self-contained and avoids introducing an additional vector-database service.

## Workspace and Semantic Retrieval

A persistent AnythingLLM workspace named:

Corporate Test

with slug:

corporate-test

was used for RAG verification.

A small Project Bingo document containing:

Project Bingo begins on September 2.
Project Manager: Bob Doe.

was embedded using the native MiniLM provider.

Semantic retrieval was then tested independently of the missing generation LLM.

Example query:

Who is responsible for Project Bingo?

The highest-ranked retrieved content contained:

Project Manager: Bob Doe.

This demonstrates semantic matching rather than exact string matching: the query uses "responsible for" while the source uses "Project Manager."

Vector retrieval succeeded while the external generation service at port 8000 was unavailable, independently demonstrating:

Native CPU embedding  -> working
LanceDB storage       -> working
Semantic retrieval    -> working
Generation dependency -> separate

## Developer API

AnythingLLM's Developer API is enabled for internal integration.

An API key can be generated through the AnythingLLM Developer API settings page.

Authentication can be verified with:

curl -sS \
  http://localhost:3001/api/v1/auth \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}"

Expected result:

{
  "authenticated": true
}

Semantic vector search was tested using:

POST /api/v1/workspace/corporate-test/vector-search

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
## AnythingLLM Direct-Ingestion Tests

A separate workspace was created for direct-ingestion testing:

direct-ingestion-test

The objective was to determine which formats AnythingLLM can consume usefully without first passing through Unstructured.

Testing should be judged by all three stages:

upload accepted
embedding succeeds
extracted content is semantically retrievable
Test results

TODO before submission: Replace this table with the actual recorded results from the direct-ingestion tests.

Format	Upload	Embedded	Semantic retrieval	Recommendation
PDF	TODO	TODO	TODO	TODO
DOCX	TODO	TODO	TODO	TODO
PPTX	TODO	TODO	TODO	TODO
HTML	TODO	TODO	TODO	TODO

Even where direct ingestion succeeds, the Unstructured path remains useful when deterministic chunking, normalized output, and explicit provenance metadata are required.

The preferred controlled path for corporate ingestion is therefore:

raw source
   ↓
Unstructured
   ↓
normalized + metadata-preserving chunks
   ↓
AnythingLLM

rather than relying exclusively on format-specific behavior inside the downstream application.

## Deployment
Unstructured
cd ~/unstructured-stack

cp .env.example .env
**Edit deployment-specific values.**

docker compose up -d
docker compose ps

Run preprocessing:

./preprocess.sh <filename>
AnythingLLM
cd ~/anythingllm-stack

cp .env.example .env
**Edit deployment-specific values and generate secrets.**

docker compose up -d
docker compose ps

AnythingLLM UI:

http://localhost:3001

Unstructured host API:

http://localhost:8001/general/v0/general

## Health / Verification Checks

Containers
cd ~/unstructured-stack
docker compose ps

cd ~/anythingllm-stack
docker compose ps

AnythingLLM should report healthy.

Shared network
docker network inspect "${SHARED_NETWORK_NAME}" \
  --format '{{range .Containers}}{{println .Name .IPv4Address}}{{end}}'

Both containers should be present.

Unstructured API
curl -i http://localhost:8001/general/v0/general

Expected GET response:

405 Method Not Allowed
Inter-container connectivity

From AnythingLLM:

docker compose exec anythingllm getent hosts unstructured

and:

docker compose exec anythingllm \
  curl -i http://unstructured:8000/general/v0/general
Vault isolation

Unstructured should be able to write beneath /vault/corporate.

AnythingLLM should fail:

docker compose exec anythingllm \
  touch /vault/corporate/write-test

with:

Read-only file system
Generation / embedding separation
docker compose exec anythingllm env | \
  grep -E 'LLM_PROVIDER|GENERIC_OPEN_AI|EMBEDDING_ENGINE|EMBEDDING_MODEL|VECTOR_DB'

Expected configuration includes:

LLM_PROVIDER=generic-openai
GENERIC_OPEN_AI_BASE_PATH=http://host.docker.internal:8000/v1

EMBEDDING_ENGINE=native
EMBEDDING_MODEL_PREF=Xenova/all-MiniLM-L6-v2

VECTOR_DB=lancedb
## Verification Checklist

The following were verified during implementation:

Two independent Docker Compose stacks

Both start with docker compose up -d

External shared Docker network

Network name supplied through environment configuration

Host corporate path supplied through environment configuration

Neither stack mounts the parent /vault directory

Unstructured receives read/write access to /vault/corporate

AnythingLLM receives read-only access to /vault/corporate

AnythingLLM persistent storage survives container recreation

PDF preprocessing

DOCX preprocessing

PPTX preprocessing

HTML parser behavior tested and documented

Repeatable raw -> processed preprocessing command

Explicit title-aware chunking policy

Maximum chunk size verified

Source metadata retained

Original contributing elements retained

Existing OpenAI-compatible generation endpoint parameterized

Generation model name externalized

API credential externalized

Signing secrets externalized

CPU-native embedding model configured separately from generation

LanceDB vector persistence

Persistent AnythingLLM workspace

Developer API authentication

Semantic retrieval verified without generation model

Inter-container DNS / shared-network communication

Full stop/start deployment rehearsal

Direct-ingestion test table finalized with recorded results

Arbitrary HTML file-input fallback, if required beyond the tested structured HTML path

## Security Notes

The implementation uses the container mount boundary rather than application convention to enforce vault access.

Neither container receives visibility into the parent knowledge vault.

AnythingLLM's access is additionally read-only.

Secrets are not embedded in docker-compose.yml.

Local .env files should not be committed.

Production API keys and AnythingLLM signing values should be generated or injected specifically for the target host.

## Known Limitations / Assumptions
The supplied OpenAI-compatible generation service was not available in the development environment. Its address and model are parameterized according to the target specification.
Semantic embedding and vector retrieval were verified independently of the generation dependency.
The tested Unstructured build exhibited differing HTML behavior between normal file-based input and its text/document-oriented parser paths. Structured HTML was successfully processed. Arbitrary HTML ingestion should receive a small normalization/text-input fallback if that behavior remains present in the target image.
The current preprocessing workflow is intentionally explicit rather than a filesystem watcher. Documents are processed one at a time through preprocess.sh, reducing accidental access or ingestion outside the intended corporate source path.
Chunking parameters are deliberately conservative defaults for this assessment and should be tuned against real corporate documents if document size, structure, or retrieval characteristics differ significantly.
Summary

The deployment establishes a self-hosted document-to-RAG pipeline with:

scoped filesystem access
independent Docker Compose stacks
external shared networking
document normalization and explicit chunking
retained source provenance
persistent AnythingLLM state
CPU-native embeddings
local vector retrieval
a separately configured GPU generation service
an authenticated API surface for future internal integration

The implementation intentionally keeps generation, embeddings, document preprocessing, persistent application state, and host corporate storage as separate concerns so that each can be deployed, tested, and replaced independently.
