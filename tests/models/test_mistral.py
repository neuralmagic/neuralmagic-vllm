"""Compare the outputs of HF and vLLM for Mistral models using greedy sampling.

Run `pytest tests/models/test_mistral.py`.
"""
import pytest

from tests.nm_utils.utils_skip import should_skip_test_group

from .utils import check_logprobs_close

if should_skip_test_group(group_name="TEST_MODELS"):
    pytest.skip("TEST_MODELS=0, skipping model test group",
                allow_module_level=True)

MODELS = [
    "mistralai/Mistral-7B-Instruct-v0.1",
    "mistralai/Mistral-7B-Instruct-v0.3",
]


# UPSTREAM SYNC: we run OOM on the A10g instances.
@pytest.mark.skip("Not enough memory in automation testing.")
@pytest.mark.parametrize("model", MODELS)
@pytest.mark.parametrize("dtype", ["bfloat16"])
@pytest.mark.parametrize("max_tokens", [64])
@pytest.mark.parametrize("num_logprobs", [5])
def test_models(
    hf_runner,
    vllm_runner,
    example_prompts,
    model: str,
    dtype: str,
    max_tokens: int,
    num_logprobs: int,
) -> None:
    # TODO(sang): Sliding window should be tested separately.
    hf_model = hf_runner(model, dtype=dtype)
    hf_outputs = hf_model.generate_greedy_logprobs_limit(
        example_prompts, max_tokens, num_logprobs)
    del hf_model

    vllm_model = vllm_runner(model, dtype=dtype)
    vllm_outputs = vllm_model.generate_greedy_logprobs(example_prompts,
                                                       max_tokens,
                                                       num_logprobs)
    del vllm_model
    check_logprobs_close(
        outputs_0_lst=hf_outputs,
        outputs_1_lst=vllm_outputs,
        name_0="hf",
        name_1="vllm",
    )
