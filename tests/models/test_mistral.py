"""Compare the outputs of HF and vLLM for Mistral models using greedy sampling.

Run `pytest tests/models/test_mistral.py`.
"""
import pytest

from tests.utils_skip import should_skip_models_test_group

MODELS = [
    "mistralai/Mistral-7B-Instruct-v0.1",
]


# UPSTREAM SYNC: we run OOM on the A10g instances.
@pytest.mark.skipif(should_skip_models_test_group(),
                    reason="Current job configured to skip this test group")
@pytest.mark.skip("Not enough memory in automation testing.")
@pytest.mark.parametrize("model", MODELS)
@pytest.mark.parametrize("dtype", ["bfloat16"])
@pytest.mark.parametrize("max_tokens", [128])
@pytest.mark.skip(
    "Two problems: 1. Failing correctness tests. 2. RuntimeError: expected "
    "scalar type BFloat16 but found Half (only in CI).")
def test_models(
    hf_runner,
    vllm_runner,
    example_long_prompts,
    model: str,
    dtype: str,
    max_tokens: int,
) -> None:
    hf_model = hf_runner(model, dtype=dtype)
    hf_outputs = hf_model.generate_greedy(example_long_prompts, max_tokens)
    del hf_model

    vllm_model = vllm_runner(model, dtype=dtype)
    vllm_outputs = vllm_model.generate_greedy(example_long_prompts, max_tokens)
    del vllm_model

    for i in range(len(example_long_prompts)):
        hf_output_ids, hf_output_str = hf_outputs[i]
        vllm_output_ids, vllm_output_str = vllm_outputs[i]
        assert hf_output_str == vllm_output_str, (
            f"Test{i}:\nHF: {hf_output_str!r}\nvLLM: {vllm_output_str!r}")
        assert hf_output_ids == vllm_output_ids, (
            f"Test{i}:\nHF: {hf_output_ids}\nvLLM: {vllm_output_ids}")
