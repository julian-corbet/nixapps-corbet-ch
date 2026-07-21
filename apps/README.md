# Apps

Extraction targets:

1. `llm-serving/` — flagship: the shared LLM lane (llama-swap + llama.cpp
   broker, LiteLLM front door, store-derived config generator). Implements
   nixgpu contract behaviors B4/B10/B14/B15.
2. Further tenants (image generation, TTS, …) as they are generalized.
