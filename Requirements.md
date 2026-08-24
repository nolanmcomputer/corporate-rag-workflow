Two completely separate Compose stacks.


~/unstructured-stack/ and ~/anythingllm-stack/.


Each gets docker-compose.yml, .env.example, and data/.


Both join an already-existing external Docker network.


Network name comes from .env, never hardcoded.


/vault/corporate is the only vault directory either stack can see.


Unstructured gets it read/write.


AnythingLLM gets it read-only.


Host vault path comes from .env.


Nothing secret appears in Compose.


Existing generative LLM is at http://host.docker.internal:8000/v1.


Existing LLM is for generation only.


Embeddings use a small CPU model.


AnythingLLM needs persistent data.


AnythingLLM needs to expose an API for a future internal service.


README has to demonstrate the whole thing works.