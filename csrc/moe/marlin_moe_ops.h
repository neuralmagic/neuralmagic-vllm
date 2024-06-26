#pragma once

#include <torch/all.h>

torch::Tensor marlin_gemm_moe(
    const torch::Tensor& a, const torch::Tensor& b_q_weights,
    const torch::Tensor& sorted_ids, const torch::Tensor& topk_weights,
    const torch::Tensor& b_scales, const torch::Tensor& expert_offsets,
    torch::Tensor& workspace, int64_t size_m, int64_t size_n, int64_t size_k,
    int64_t num_tokens_post_padded, int64_t num_experts, int64_t topk,
    int64_t moe_block_size, bool replicate_input, bool apply_weights);
