#pragma once

#include "cuda/marlinv2/marlinv2_prepack_kernel.cuh"
#include "cuda/utilities/torch_utils.cuh"

namespace marlinv2 {

template <typename PrepackedLayout>
torch::Tensor prepack_impl(torch::Tensor const B) {
  const at::cuda::OptionalCUDAGuard device_guard(device_of(B));

  auto device = B.device();
  auto stream = at::cuda::getCurrentCUDAStream(device.index());

  using ElementB = typename PrepackedLayout::ElementB;
  using StrideB  = cutlass::detail::TagToStrideB_t<cutlass::layout::ColumnMajor>;

  auto B_ptr = data_ptr<ElementB const, cutlass::layout::ColumnMajor>(B, "B");

  auto elements_per_storage_item = (B.dtype().itemsize() * 8) / cute::sizeof_bits_v<ElementB>;

  int N = B.size(0) * elements_per_storage_item;
  int M = B.size(1);

  // elements per storage type

  auto const shape_Bt = cute::make_shape(M, N, 1);
  auto const stride_B = make_cute_packed_stride(StrideB{}, shape_Bt);

  // Allocate output
  torch::Tensor D = torch::empty_like(B);

  prepack_B<PrepackedLayout>(stream, B_ptr, make_layout(shape_Bt, stride_B),
                             reinterpret_cast<ElementB*>(D.mutable_data_ptr()));

  return D;
};

template <typename ElementA, typename ElementB, typename ElementD, typename AccumulatorT = float,
          typename ScaleT = cutlass::half_t, typename ZeroT = cutlass::half_t>
struct PrepackDispatcher {
  static torch::Tensor dispatch(torch::Tensor B);
};

}; // namespace marlinv2