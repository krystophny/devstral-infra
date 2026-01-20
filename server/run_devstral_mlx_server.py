#!/usr/bin/env python3
import os

import mlx_lm.server as s

class PromptTooLongError(ValueError):
    pass

class LimitedResponseGenerator(s.ResponseGenerator):
    def __init__(self, *args, max_prompt_tokens: int, **kwargs):
        super().__init__(*args, **kwargs)
        self._max_prompt_tokens = int(max_prompt_tokens)

    def _tokenize(self, tokenizer, request):
        tokens = super()._tokenize(tokenizer, request)
        if len(tokens) > self._max_prompt_tokens:
            raise PromptTooLongError(
                f"prompt too long: {len(tokens)} tokens (limit {self._max_prompt_tokens})"
            )
        return tokens

def main() -> None:
    # Default to 128k prompt budget unless overridden.
    max_prompt_tokens = int(os.environ.get("DEVSTRAL_MAX_PROMPT_TOKENS", "131072"))

    class PatchedResponseGenerator(LimitedResponseGenerator):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs, max_prompt_tokens=max_prompt_tokens)

    # Monkey-patch the class that `mlx_lm.server.run()` instantiates.
    s.ResponseGenerator = PatchedResponseGenerator  # type: ignore[assignment]

    s.main()

if __name__ == "__main__":
    main()
