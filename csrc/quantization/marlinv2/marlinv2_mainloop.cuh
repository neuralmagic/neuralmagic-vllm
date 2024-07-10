// Based off of:
//   cutlass/gemm/collective/sm90_mma_tma_gmma_rs_warpspecialized_mixed_input.hpp
#pragma once

// clang-format off
#include "cutlass/cutlass.h"
#include "cutlass/numeric_conversion.h"
#include "cute/arch/cluster_sm90.hpp"
#include "cute/arch/copy_sm90.hpp"
#include "cutlass/gemm/gemm.h"
#include "cutlass/detail/dependent_false.hpp"
#include "cutlass/gemm/dispatch_policy.hpp"
#include "cutlass/detail/layout.hpp"

#include "cute/algorithm/functional.hpp"
#include "cute/atom/mma_atom.hpp"
#include "cute/atom/copy_traits_sm90_tma.hpp"
#include "cute/algorithm/gemm.hpp"
#include "cute/tensor_predicate.hpp"
#include "cute/numeric/arithmetic_tuple.hpp"
#include "cutlass/pipeline/pipeline.hpp"
#include "cutlass/transform/collective/sm90_wgmma_transpose.hpp"
#include "cutlass/trace.h"

#include "cutlass/detail/collective.hpp"
// clang-format on

#include "math_utils.h"
#include "cutlass_extensions/cute_utils.cuh"

/////////////////////////////////////////////////////////////////////////////////////////////////

namespace marlinv2 {

using namespace cute;
using namespace cutlass;
using namespace cutlass::gemm;
using namespace cutlass::gemm::collective;
using namespace cutlass::gemm::collective::detail;

struct APrepackedLayout {};

/////////////////////////////////////////////////////////////////////////////////////////////////

// WarpSpecialized Mainloop that source A operand from registers
template <class ElementATuple_, class GmemLayoutA, int AlignmentA,
          class ElementB_, class GmemLayoutB, int AlignmentB,
          class ElementAccumulator_, class TileShape_MNK,
          class ClusterShape_MNK, class StageCountType,
          class KernelScheduleType>
struct MarlinV2CollectiveMma {
  using Schedule = KernelScheduleType;
  static_assert(
      cute::is_same_v<Schedule, KernelTmaWarpSpecialized> ||
          cute::is_same_v<Schedule, KernelTmaWarpSpecializedMixedInput> ||
          cute::is_same_v<Schedule, KernelTmaWarpSpecializedPingpong> ||
          cute::is_same_v<Schedule,
                          KernelTmaWarpSpecializedPingpongMixedInput> ||
          cute::is_same_v<Schedule, KernelTmaWarpSpecializedCooperative> ||
          cute::is_same_v<Schedule,
                          KernelTmaWarpSpecializedCooperativeMixedInput>,
      "KernelSchedule must be one of the warp specialized policies");

 public:
  static constexpr bool ALayoutIsPrepacked = true;

  using PPBlockShape_MK = typename GmemLayoutA::PPBlockShape_MK;
  using PPBlocksPerTile_MK = decltype(make_shape(
      size<0>(TileShape_MNK{}) / size<0>(PPBlockShape_MK{}),
      size<2>(TileShape_MNK{}) / size<1>(PPBlockShape_MK{})));

  static_assert(size<0>(TileShape_MNK{}) % size<0>(PPBlockShape_MK{}) == 0,
                "M in PPBlockShape_MK must evenly divide M TileShape_MNK");
  static_assert(size<2>(TileShape_MNK{}) % size<1>(PPBlockShape_MK{}) == 0,
                "K in PPBlockShape_MK must evenly divide K TileShape_MNK");

  // Required by kernel
  using StandardGmemLayoutA = cutlass::layout::RowMajor;

  using ArchTag = arch::Sm90;
  using TileShape = TileShape_MNK;
  using ClusterShape = ClusterShape_MNK;
  using ElementA = deduce_mixed_width_dtype_t<0, ElementATuple_>;
  using StrideA = TagToStrideA_t<StandardGmemLayoutA>;
  using ElementB = ElementB_;
  using StrideB = TagToStrideB_t<GmemLayoutB>;
  using ElementAccumulator = ElementAccumulator_;
  using ElementMma = ElementB;
  using ElementATuple =
      cute::conditional_t<!cute::is_tuple<ElementATuple_>::value,
                          cute::tuple<ElementA>, ElementATuple_>;

  static constexpr cute::GMMA::Major GmmaMajorA =
      gmma_rs_tag_to_major_A<StandardGmemLayoutA>();
  static constexpr cute::GMMA::Major GmmaMajorB =
      gmma_rs_tag_to_major_B<GmemLayoutB>();
  using AtomLayoutMNK = cute::conditional_t<
      cute::is_same_v<KernelScheduleType,
                      KernelTmaWarpSpecializedCooperativeMixedInput>,
      Layout<Shape<_2, _1, _1>>, Layout<Shape<_1, _1, _1>>>;

  // Required by kernel
  using TiledMma = decltype(cute::make_tiled_mma(
      cute::GMMA::rs_op_selector<ElementMma, ElementMma, ElementAccumulator,
                                 TileShape_MNK, GMMA::Major::K, GmmaMajorB>(),
      AtomLayoutMNK{}));

 private:
  using ElementScale = deduce_mixed_width_dtype_t<1, ElementATuple_>;
  using ElementZero = deduce_mixed_width_dtype_t<2, ElementATuple_>;

  static constexpr bool IsANarrow = cutlass::sizeof_bits<ElementA>::value <
                                    cutlass::sizeof_bits<ElementB>::value;
  static_assert(IsANarrow,
                "A must be the narrow one since its the one that flows through "
                "registers.");
  static constexpr bool IsWarpSpecializedTransposeB =
      is_warpspecialized_transpose_B<ElementA, StandardGmemLayoutA, ElementB,
                                     GmemLayoutB, KernelScheduleType>();

 public:
  static constexpr int PipelineStages =
      compute_stage_count_or_override_single_affine_transformed_input<
          sm90_smem_capacity_bytes, ElementA, ElementB, ElementScale,
          ElementZero, TileShape_MNK>(StageCountType{});

  // Required by kernel
  struct DispatchPolicy {
    constexpr static int Stages = PipelineStages;
    using ClusterShape = ClusterShape_MNK;
    using Schedule = KernelScheduleType;
  };

  using GmemTiledCopyA =
      decltype(sm90_cluster_shape_to_tma_atom(shape<1>(ClusterShape_MNK{})));
  using GmemTiledCopyB =
      decltype(sm90_cluster_shape_to_tma_atom(shape<0>(ClusterShape_MNK{})));

  // ((T, V), BlocksM, BlocksK, pipe) -> offset
  using SmemLayoutAPrepacked = decltype(GmemLayoutA::pp_TVbMbKL_to_offset(
      make_shape(size<0>(TileShape_MNK{}), size<2>(TileShape_MNK{}),
                 Int<DispatchPolicy::Stages>{})));

  using SmemLayoutAtomAStandard =
      decltype(rs_smem_selector<GmmaMajorA, ElementA,
                                decltype(cute::get<0>(TileShape_MNK{})),
                                decltype(cute::get<2>(TileShape_MNK{})),
                                IsWarpSpecializedTransposeB>());

  static_assert(cute::rank(SmemLayoutAtomAStandard{}) == 2,
                "SmemLayoutAtom must be rank 2 (M/N, K)");
  static_assert((size<0>(TileShape{}) % size<0>(SmemLayoutAtomAStandard{})) ==
                    0,
                "SmemLayoutAtom must evenly divide tile shape.");
  static_assert((size<2>(TileShape{}) % size<1>(SmemLayoutAtomAStandard{})) ==
                    0,
                "SmemLayoutAtom must evenly divide tile shape.");

  using SmemLayoutAtomB =
      decltype(rs_smem_selector<GmmaMajorB, ElementB,
                                decltype(cute::get<1>(TileShape_MNK{})),
                                decltype(cute::get<2>(TileShape_MNK{})),
                                IsWarpSpecializedTransposeB>());

  using SmemCopyAtomA = Copy_Atom<cute::DefaultCopy, ElementA>;
  using SmemCopyAtomB = void;

  //
  //  Validity checks
  //
  static_assert(is_static<TileShape_MNK>::value);
  static_assert(is_static<ClusterShape_MNK>::value);
  static_assert(is_aligned<ElementA, AlignmentA, ElementB, AlignmentB,
                           tma_alignment_bytes>(),
                "Should meet TMA alignment requirement\n");
#ifndef CUTLASS_SM90_COLLECTIVE_BUILDER_SUPPORTED
  static_assert(cutlass::detail::dependent_false<ElementA>,
                "Unsupported Toolkit for SM90 Collective Builder\n");
#endif
  static_assert(!IsWarpSpecializedTransposeB,
                "Mixed input GEMM does not support WS transpose B.");

 private:
  enum class ConversionMode {
    DirectConvert,
    ConvertAndScale,
    ConvertAndScaleWithZero
  };

 public:
  //
  // Type Aliases
  //
  using KernelSchedule = KernelScheduleType;

  // For cases where we can't have a void type, we can use this to allow the
  // code to compile when the scale / zero is void.
  using NonVoidElementScale =
      cute::conditional_t<cute::is_void_v<ElementScale>, float, ElementScale>;
  using NonVoidElementZero =
      cute::conditional_t<cute::is_void_v<ElementZero>, float, ElementZero>;

  // These are always MN major
  using StrideScale = cute::Stride<cute::Int<1>, int64_t, int64_t>;
  // For cases where we can't have a void scale, we can use this to allow the
  // code to compile when the scale is void.
  using NonVoidStrideScale =
      cute::conditional_t<cute::is_void_v<StrideScale>,
                          cute::Stride<_1, int64_t, int64_t>, StrideScale>;

  static_assert((cutlass::gemm::detail::is_k_major<StrideA>()),
                "The transformed matrix (A) must be K-major.");

  static_assert((sizeof(ElementB) == 2) ||
                    (cutlass::gemm::detail::is_k_major<StrideA>() &&
                     cutlass::gemm::detail::is_k_major<StrideB>()),
                "The unscaled element (matrix B) must be 2 bytes OR both "
                "inputs must be K-major");

  static_assert(cutlass::gemm::detail::is_mn_major<NonVoidStrideScale>(),
                "Scale must be MN major [Col Major if A is scaled, Row Major "
                "if B is scaled].");

  static_assert(std::is_same_v<typename TiledMma::ValTypeC, ElementAccumulator>,
                "TiledMma::ValTypeC must be the same as ElementAccumulator.");

  using GmemTiledCopyScale = cute::SM90_TMA_LOAD;

  using SmemCopyAtomScale = Copy_Atom<cute::DefaultCopy, NonVoidElementScale>;

  // Swap and transpose A/B for A k-major layout and B mn-major layout since
  // WGMMA is k-major only (e.g. tf32, Fp32, Int8, Fp8 WGMMA)
  static constexpr bool IsLayoutAkBmn =
      cute::is_same_v<gemm::detail::StrideToLayoutTagA_t<StrideA>,
                      layout::RowMajor> &&
      cute::is_same_v<gemm::detail::StrideToLayoutTagB_t<StrideB>,
                      layout::RowMajor>;

  static constexpr bool IsInputSizeTwoBytes =
      sizeof(ElementA) == 2 && sizeof(ElementB) == 2;

  // TMA converts f32 input to tf32 when copying from GMEM to SMEM
  // For all other types, cast to size equivalent uint type to avoid any
  // rounding by TMA.
  static constexpr bool ConvertF32toTF32A = cute::is_same_v<float, ElementA>;
  static constexpr bool ConvertF32toTF32B = cute::is_same_v<float, ElementB>;
  using InternalElementA =
      cute::conditional_t<ConvertF32toTF32A, tfloat32_t,
                          uint_bit_t<sizeof_bits_v<ElementA>>>;
  using InternalElementB =
      cute::conditional_t<ConvertF32toTF32B, tfloat32_t,
                          uint_bit_t<sizeof_bits_v<ElementB>>>;

  using TransformA = cute::identity;
  using TransformB = cute::identity;

  static constexpr int IsSubbyteA = cute::sizeof_bits_v<InternalElementA> < 8;
  using TmaElementA =
      cute::conditional_t<IsSubbyteA, uint8_t, InternalElementA>;

  using MainloopPipeline = cutlass::PipelineTmaAsync<DispatchPolicy::Stages>;
  using PipelineState = cutlass::PipelineState<DispatchPolicy::Stages>;

  using PipelineParams = typename MainloopPipeline::Params;

  using SmemLayoutAtomScale = Layout<
      Shape<decltype(cute::shape<0>(SmemLayoutAtomAStandard{})), cute::Int<1>>>;
  using ScaleTileShape = decltype(make_shape(shape<0>(TileShape{}),
                                             shape<1>(SmemLayoutAtomScale{})));

  static_assert(cute::rank(SmemLayoutAtomB{}) == 2,
                "SmemLayoutAtom must be rank 2 (M/N, K)");
  static_assert((size<1>(TileShape{}) % size<0>(SmemLayoutAtomB{})) == 0,
                "SmemLayoutAtom must evenly divide tile shape.");
  static_assert((size<2>(TileShape{}) % size<1>(SmemLayoutAtomB{})) == 0,
                "SmemLayoutAtom must evenly divide tile shape.");

  static_assert(rank(SmemLayoutAtomScale{}) == 2,
                "SmemLayoutAtomScale must be rank 2");
  static_assert((size<0>(TileShape{}) % size<0>(SmemLayoutAtomScale{})) == 0,
                "SmemLayoutAtomScale must equal the tile shape.");
  static_assert((size<2>(TileShape{}) % size<1>(SmemLayoutAtomScale{})) == 0,
                "SmemLayoutAtomScale must evenly divide tile k shape.");

  // Tile along modes in a way that maximizes the TMA box size.
  using SmemLayoutAStandard = decltype(tile_to_shape(
      SmemLayoutAtomAStandard{},
      make_shape(shape<0>(TileShape{}), shape<2>(TileShape{}),
                 Int<DispatchPolicy::Stages>{}),
      conditional_t<::cutlass::gemm::detail::is_major<0, StrideA>(),
                    Step<_2, _1, _3>, Step<_1, _2, _3>>{}));

  using SmemLayoutA = SmemLayoutAStandard;

  using SmemLayoutB = decltype(tile_to_shape(
      SmemLayoutAtomB{},
      make_shape(shape<1>(TileShape{}), shape<2>(TileShape{}),
                 Int<DispatchPolicy::Stages>{}),
      conditional_t<::cutlass::gemm::detail::is_major<0, StrideB>(),
                    Step<_2, _1, _3>, Step<_1, _2, _3>>{}));

  // It is assumed that the scales and zero-points share the same smem layout
  using SmemLayoutScale = decltype(tile_to_shape(
      SmemLayoutAtomScale{},
      make_shape(shape<0>(ScaleTileShape{}), shape<1>(ScaleTileShape{}),
                 Int<PipelineStages>{})));

  // If A mn-layout and B mn-layout, transposing B matrix since WGMMA is k-major
  // only (e.g. tf32, fp32, fp8, int8).
  static constexpr bool IsLayoutAmnBmn =
      cute::is_same_v<gemm::detail::StrideToLayoutTagA_t<StrideA>,
                      layout::ColumnMajor> &&
      cute::is_same_v<gemm::detail::StrideToLayoutTagB_t<StrideB>,
                      layout::RowMajor>;
  static constexpr bool TransposeB = !IsInputSizeTwoBytes && IsLayoutAmnBmn;
  using TransposeOperandB =
      decltype(cutlass::transform::collective::detail::make_transpose_operand_b(
          0, 0, TiledMma{}, SmemLayoutB{}, SmemLayoutAtomB{},
          InternalElementB{}, cute::bool_constant<TransposeB>{}));

  static_assert(DispatchPolicy::Stages >= 2,
                "Specialization requires Stages set to value 2 or more.");
  static_assert(not cute::is_base_of<cute::GMMA::DescriptorIterator,
                                     typename TiledMma::FrgTypeA>::value &&
                    cute::is_base_of<cute::GMMA::DescriptorIterator,
                                     typename TiledMma::FrgTypeB>::value,
                "MMA atom must source A from rmem and B operand from smem_desc "
                "for this mainloop.");
  static_assert(cute::is_same_v<GmemTiledCopyA, SM90_TMA_LOAD> ||
                    cute::is_same_v<GmemTiledCopyA, SM90_TMA_LOAD_MULTICAST>,
                "GmemTiledCopy - invalid SM90 TMA copy atom specified.");
  static_assert(cute::is_same_v<GmemTiledCopyB, SM90_TMA_LOAD> ||
                    cute::is_same_v<GmemTiledCopyB, SM90_TMA_LOAD_MULTICAST>,
                "GmemTiledCopy - invalid SM90 TMA copy atom specified.");

  using GmmaSmemLayoutAtomB =
      decltype(transform::collective::detail::
                   gmma_smem_transpose_or_passthrough<
                       TransposeB, SmemLayoutAtomB, InternalElementB>());

  // SmemLayoutB for GMMA is different from SmemLayoutB for TMA if TransposeB
  using GmmaSmemLayoutB = decltype(tile_to_shape(
      GmmaSmemLayoutAtomB{},
      make_shape(shape<1>(TileShape{}), shape<2>(TileShape{}),
                 Int<DispatchPolicy::Stages>{}),
      conditional_t<::cutlass::gemm::detail::is_major<0, StrideB>(),
                    Step<_2, _1, _3>, Step<_1, _2, _3>>{}));

  // These two restrictions are related, so we place the assertions together.
  // To relax them, we need to handle loading more than 1 row of scales for
  // every main loop iteration. We must also handle updating the pipeline
  // transaction bytes on the fly. NOTE: Deleting this assertion without
  // required changes will cause the code to hang.
  static_assert(size<1>(SmemLayoutAtomScale{}) == 1,
                "size<1>(SmemLayoutAtomScale) must be 1.");

  static_assert(TransposeB xor (cute::is_same_v<SmemLayoutB, GmmaSmemLayoutB>),
                "Should be same layout if not TransposeB.");
  static_assert(!TransposeB || size<1>(SmemLayoutB{}) *
                                       cute::sizeof_bits_v<InternalElementB> /
                                       8 ==
                                   128,
                "SmemLayoutB K must be 128bytes to be transposed.");

 public:  // TODO: make private
  static constexpr ConversionMode get_conversion_mode() {
    if constexpr (cute::is_void_v<ElementScale>) {
      return ConversionMode::DirectConvert;
    } else if constexpr (cute::is_void_v<ElementZero>) {
      return ConversionMode::ConvertAndScale;
    } else {
      return ConversionMode::ConvertAndScaleWithZero;
    }
  }

  static constexpr ConversionMode KernelConversionMode = get_conversion_mode();
  static constexpr bool ModeHasScales =
      KernelConversionMode == ConversionMode::ConvertAndScale ||
      KernelConversionMode == ConversionMode::ConvertAndScaleWithZero;

  static constexpr auto elements_per_smem_scale() {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      return 0;
    } else if constexpr (ModeHasScales) {
      return cute::cosize_v<SmemLayoutScale>;
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Type not handled in scale smem allocation.");
    }
  }

  static constexpr auto elements_per_smem_zero() {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert ||
                  KernelConversionMode == ConversionMode::ConvertAndScale) {
      return 0;
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScaleWithZero) {
      return cute::cosize_v<SmemLayoutScale>;
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Type not handled in scale smem allocation.");
    }
  }

  // These methods use some the public members of the class. For that reason, we
  // define them after the public section.
  static constexpr uint32_t compute_tma_transaction_bytes() {
    constexpr uint32_t a_bytes =
        (size<0>(SmemLayoutA{}) * size<1>(SmemLayoutA{}) *
         static_cast<uint32_t>(cute::sizeof_bits_v<InternalElementA>) / 8);
    constexpr uint32_t b_bytes =
        (size<0>(SmemLayoutB{}) * size<1>(SmemLayoutB{}) *
         static_cast<uint32_t>(cute::sizeof_bits_v<InternalElementB>) / 8);

    constexpr uint32_t baseline_bytes = a_bytes + b_bytes;

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      return baseline_bytes;
    } else if constexpr (ModeHasScales) {
      constexpr uint32_t scale_tx_bytes =
          (size<0>(SmemLayoutScale{}) * size<1>(SmemLayoutScale{}) *
           static_cast<uint32_t>(cute::sizeof_bits_v<ElementScale>) / 8);
      static_assert(
          scale_tx_bytes % 128 == 0,
          "Each scale stage must be 128B aligned.");  // required by TMA
      if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
        return baseline_bytes + scale_tx_bytes;
      } else if constexpr (KernelConversionMode ==
                           ConversionMode::ConvertAndScaleWithZero) {
        // Scale and zero share smem layout
        constexpr uint32_t zero_tx_bytes =
            (size<0>(SmemLayoutScale{}) * size<1>(SmemLayoutScale{}) *
             static_cast<uint32_t>(cute::sizeof_bits_v<ElementZero>) / 8);
        static_assert(
            zero_tx_bytes % 128 == 0,
            "Each zero stage must be 128B aligned.");  // required by TMA
        return baseline_bytes + scale_tx_bytes + zero_tx_bytes;
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Type not handled in tma transaction bytes computation.");
      }
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Type not handled in tma transaction bytes computation.");
    }
  }

  using AStandardTensor = decltype(make_tensor(
      get_logical_ptr(static_cast<InternalElementA const*>(nullptr)),
      repeat_like(StrideA{}, int32_t(0)), StrideA{}));

  // ((athrid, val), TilesM, TilesK, L) -> (storage_idx)
  using PrepackedStrideA = decltype(stride(GmemLayoutA::pp_TVbMbKL_to_offset(
      make_shape(int32_t(0), int32_t(0), int32_t(0)))));

  using APrepackedTensor = decltype(make_tensor(
      get_logical_ptr(static_cast<InternalElementA const*>(nullptr)),
      shape(GmemLayoutA::pp_TVbMbKL_to_offset(
          make_shape(int32_t(0), int32_t(0), int32_t(0)))),
      PrepackedStrideA{}));

  using ATensor =
      std::conditional_t<ALayoutIsPrepacked, APrepackedTensor, AStandardTensor>;

  using ScaleTensor = decltype(make_tensor(
      get_logical_ptr(static_cast<NonVoidElementScale const*>(nullptr)),
      repeat_like(NonVoidStrideScale{}, int32_t(0)), NonVoidStrideScale{}));

  using ZeroTensor = decltype(make_tensor(
      get_logical_ptr(static_cast<NonVoidElementZero const*>(nullptr)),
      repeat_like(NonVoidStrideScale{}, int32_t(0)), NonVoidStrideScale{}));

  using BTensor = decltype(make_tensor(
      get_logical_ptr(static_cast<InternalElementB const*>(nullptr)),
      repeat_like(StrideB{}, int32_t(0)), StrideB{}));

  static constexpr auto make_tma_copy_A(ATensor tensor_a = ATensor{}) {
    if constexpr (ALayoutIsPrepacked) {
      return make_tma_copy<TmaElementA>(
          GmemTiledCopyA{}, tensor_a,
          SmemLayoutAPrepacked{}(_, _, cute::Int<0>{}),
          shape(SmemLayoutAPrepacked{}(_, _, cute::Int<0>{})),
          size<1>(
              ClusterShape{}));  // mcast along N mode for this M load, if any
    } else {
      return make_tma_copy<TmaElementA>(
          GmemTiledCopyA{}, tensor_a, SmemLayoutA{}(_, _, cute::Int<0>{}),
          make_shape(shape<0>(TileShape{}), shape<2>(TileShape{})),
          size<1>(
              ClusterShape{}));  // mcast along N mode for this M load, if any
    }
  }

  static constexpr auto make_tma_copy_scale(
      ScaleTensor tensor_scale = ScaleTensor{}) {
    return make_tma_copy(GmemTiledCopyScale{}, tensor_scale,
                         SmemLayoutScale{}(_, _, cute::Int<0>{}),
                         ScaleTileShape{},
                         _1{});  // mcast along N mode for this M load, if any
  }

  static constexpr auto make_tma_copy_zero(
      ZeroTensor tensor_zero = ZeroTensor{}) {
    return make_tma_copy(GmemTiledCopyScale{}, tensor_zero,
                         SmemLayoutScale{}(_, _, cute::Int<0>{}),
                         ScaleTileShape{},
                         _1{});  // mcast along N mode for this M load, if any
  }

  static constexpr auto make_tma_copy_B(BTensor tensor_b = BTensor{}) {
    return make_tma_copy(
        GmemTiledCopyB{}, tensor_b, SmemLayoutB{}(_, _, cute::Int<0>{}),
        make_shape(shape<1>(TileShape{}), shape<2>(TileShape{})),
        size<0>(ClusterShape{}));  // mcast along M mode for this N load, if any
  }

 public:
  static constexpr size_t SmemAlignmentA =
      cutlass::detail::alignment_for_swizzle(SmemLayoutA{});

  static constexpr size_t SmemAlignmentB =
      cutlass::detail::alignment_for_swizzle(SmemLayoutB{});

  // Just pick the max alignment of A and B since it is required to be at least
  // 128B
  static constexpr size_t SmemAlignmentScale =
      cute::max(SmemAlignmentA, SmemAlignmentB);

  static_assert(SmemAlignmentA >= 128 and SmemAlignmentB >= 128,
                "Require at least 128B alignment");

  struct SharedStorage {
    static constexpr int scale_elements = elements_per_smem_scale();
    static constexpr int zero_elements = elements_per_smem_zero();
    struct TensorStorage
        : cute::aligned_struct<cute::max(SmemAlignmentA, SmemAlignmentB)> {
      cute::ArrayEngine<ElementA, cute::cosize_v<SmemLayoutA>> smem_A;
      cute::ArrayEngine<typename TiledMma::ValTypeB,
                        cute::cosize_v<SmemLayoutB>>
          smem_B;
      cute::ArrayEngine<NonVoidElementScale, scale_elements> smem_scale;
      cute::ArrayEngine<NonVoidElementZero, zero_elements> smem_zero;
    } tensors;

    using PipelineStorage = typename MainloopPipeline::SharedStorage;
    PipelineStorage pipeline;
  };

  using TensorStorage = typename SharedStorage::TensorStorage;
  using PipelineStorage = typename SharedStorage::PipelineStorage;

  // Host side kernel arguments
  struct Arguments {
    ElementA const* ptr_A = nullptr;
    StrideA dA{};
    ElementB const* ptr_B = nullptr;
    StrideB dB{};
    ElementScale const* ptr_S = nullptr;
    NonVoidStrideScale dS{};
    int group_size = 0;
    ElementZero const* ptr_Z = nullptr;
    uint32_t mma_promotion_interval = 4;
  };

  // Device side kernel params
  struct Params {
   public:
    // Assumption: StrideA is congruent with Problem_MK
    using TMA_A = decltype(make_tma_copy_A());
    using TMA_Scale = decltype(make_tma_copy_scale());
    using TMA_Zero = decltype(make_tma_copy_zero());
    using TMA_B = decltype(make_tma_copy_B());

    TMA_A tma_load_a;
    TMA_B tma_load_b;
    TMA_Scale tma_load_scale;
    TMA_Zero tma_load_zero;
    int64_t scale_k;
    int group_size;
  };

  //
  // Methods
  //

  template <class ProblemShape>
  static constexpr Params to_underlying_arguments(
      ProblemShape const& problem_shape, Arguments const& args,
      void* workspace) {
    (void)workspace;

    // Optionally append 1s until problem shape is rank-4 (MNKL), in case it is
    // only rank-3 (MNK)
    auto problem_shape_MNKL = append<4>(problem_shape, 1);
    auto [M, N, K, L] = problem_shape_MNKL;

    auto ptr_A = reinterpret_cast<InternalElementA const*>(args.ptr_A);
    auto ptr_B = reinterpret_cast<InternalElementB const*>(args.ptr_B);

    auto make_logical_tensor = [&](auto ptr, auto shape, auto stride) {
      return make_tensor(get_logical_ptr(ptr), make_layout(shape, stride));
    };

    typename Params::TMA_A tma_load_a;
    typename Params::TMA_B tma_load_b;
    typename Params::TMA_Scale tma_load_scale;
    typename Params::TMA_Zero tma_load_zero;

    if constexpr (ALayoutIsPrepacked) {
      auto layout = GmemLayoutA::pp_TVbMbKL_to_offset(make_shape(M, K, L));
      tma_load_a = make_tma_copy_A(
          make_logical_tensor(ptr_A, shape(layout), stride(layout)));
    } else {
      tma_load_a = make_tma_copy_A(
          make_logical_tensor(ptr_A, make_shape(M, K, L), args.dA));
    }

    tma_load_b = make_tma_copy_B(
        make_logical_tensor(ptr_B, make_shape(N, K, L), args.dB));

    if constexpr (ModeHasScales) {
      tma_load_scale = make_tma_copy_scale(make_logical_tensor(
          args.ptr_S, make_shape(M, args.group_size, L), args.dS));
    }

    if constexpr (KernelConversionMode ==
                  ConversionMode::ConvertAndScaleWithZero) {
      tma_load_zero = make_tma_copy_zero(make_logical_tensor(
          args.ptr_Z, make_shape(M, args.group_size, L), args.dS));
    }

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      return {tma_load_a, tma_load_b, tma_load_scale, tma_load_zero, 0, 0};
    } else if constexpr (ModeHasScales) {
      auto scale_k = (K + args.group_size - 1) / args.group_size;

      return {tma_load_a,    tma_load_b, tma_load_scale,
              tma_load_zero, scale_k,    args.group_size};
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in to_underlying_arguments.");
    }
  }

  template <class ProblemShape>
  CUTLASS_HOST_DEVICE static bool can_implement(
      ProblemShape const& problem_shape,
      [[maybe_unused]] Arguments const& args) {
    constexpr int tma_alignment_bits = 128;
    auto problem_shape_MNKL = append<4>(problem_shape, 1);
    auto [M, N, K, L] = problem_shape_MNKL;

    bool implementable = true;
    constexpr int min_tma_aligned_elements_A =
        tma_alignment_bits / cutlass::sizeof_bits<ElementA>::value;
    implementable =
        implementable &&
        cutlass::detail::check_alignment<min_tma_aligned_elements_A>(
            cute::make_shape(M, K, L), StrideA{});
    constexpr int min_tma_aligned_elements_B =
        tma_alignment_bits / cutlass::sizeof_bits<ElementB>::value;
    implementable =
        implementable &&
        cutlass::detail::check_alignment<min_tma_aligned_elements_B>(
            cute::make_shape(N, K, L), StrideB{});

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      implementable = implementable && (args.ptr_S == nullptr);
      implementable = implementable && (args.ptr_Z == nullptr);
    } else if constexpr (ModeHasScales) {
      const int scale_mn = M;
      const int scale_k = (K + args.group_size - 1) / args.group_size;
      constexpr int min_tma_aligned_elements_scale =
          tma_alignment_bits / cutlass::sizeof_bits<ElementScale>::value;
      implementable =
          implementable &&
          cutlass::detail::check_alignment<min_tma_aligned_elements_scale>(
              cute::make_shape(scale_mn, scale_k, L), StrideScale{});
      implementable =
          implementable && (args.group_size == K ||
                            ((args.group_size % size<2>(TileShape{})) == 0));
      implementable = implementable && args.group_size != 0;
      implementable = implementable && (args.ptr_S != nullptr);

      if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
        implementable = implementable && (args.ptr_Z == nullptr);
      } else if constexpr (KernelConversionMode ==
                           ConversionMode::ConvertAndScaleWithZero) {
        constexpr int min_tma_aligned_elements_zero =
            tma_alignment_bits / cutlass::sizeof_bits<ElementZero>::value;
        implementable =
            implementable &&
            cutlass::detail::check_alignment<min_tma_aligned_elements_zero>(
                cute::make_shape(scale_mn, scale_k, L), StrideScale{});
        implementable = implementable && (args.ptr_Z != nullptr);
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Conversion mode not handled in can_implement.");
      }
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in can_implement.");
    }

    if (!implementable) {
      CUTLASS_TRACE_HOST(
          "  CAN IMPLEMENT: Problem Size doesn't meet the minimum alignment "
          "requirements for TMA.\n");
    }
    return implementable;
  }

  static constexpr int K_PIPE_MAX = DispatchPolicy::Stages;
  static constexpr uint32_t TmaTransactionBytes =
      compute_tma_transaction_bytes();

  /// Issue Tma Descriptor Prefetch -- ideally from a single thread for best
  /// performance
  CUTLASS_DEVICE
  static void prefetch_tma_descriptors(Params const& mainloop_params) {
    cute::prefetch_tma_descriptor(
        mainloop_params.tma_load_a.get_tma_descriptor());
    cute::prefetch_tma_descriptor(
        mainloop_params.tma_load_b.get_tma_descriptor());

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      // Nothing extra to do
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScale) {
      cute::prefetch_tma_descriptor(
          mainloop_params.tma_load_scale.get_tma_descriptor());
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScaleWithZero) {
      cute::prefetch_tma_descriptor(
          mainloop_params.tma_load_scale.get_tma_descriptor());
      cute::prefetch_tma_descriptor(
          mainloop_params.tma_load_zero.get_tma_descriptor());
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in TMA prefetch.");
    }
  }

  /// Set up the data needed by this collective for load and mma.
  /// Returns a tuple of tensors. The collective and the kernel layer have the
  /// contract Returned tuple must contain at least two elements, with the first
  /// two elements being: gA_mkl - The tma tensor, A after a local tile so it
  /// has shape  (BLK_M,BLK_K,m,k,l) gB_nkl - The tma tensor, B after a local
  /// tile so it has shape  (BLK_N,BLK_K,n,k,l) The rest of the tensors can be
  /// specified as needed by this collective.
  template <class ProblemShape_MNKL>
  CUTLASS_DEVICE auto load_init(ProblemShape_MNKL const& problem_shape_MNKL,
                                Params const& mainloop_params) const {
    using X = Underscore;
    auto M = get<0>(problem_shape_MNKL), N = get<1>(problem_shape_MNKL),
         K = get<2>(problem_shape_MNKL), L = get<3>(problem_shape_MNKL);

    // if prepacked
    //   (BlockV,(BlocksM, BlocksK),m,k,l)
    // else
    //   (BLK_M,BLK_K,m,k,l)
    auto make_gA_mkl = [&]() {
      if constexpr (ALayoutIsPrepacked) {
        auto pp_layout = GmemLayoutA::pp_TVbMbKL_to_offset(make_shape(M, K, L));
        Tensor mA_mkl =
            mainloop_params.tma_load_a.get_tma_tensor(shape(pp_layout));
        return local_tile(mA_mkl,
                          make_shape(size<0>(pp_layout), PPBlocksPerTile_MK{}),
                          make_coord(0, make_coord(_, _)));
      } else {
        Tensor mA_mkl =
            mainloop_params.tma_load_a.get_tma_tensor(make_shape(M, K, L));
        return local_tile(mA_mkl, TileShape{}, make_coord(_, _, _),
                          Step<_1, X, _1>{});
      }
    };

    // (BLK_N,BLK_K,n,k,l)
    auto make_gB_nkl = [&]() {
      Tensor mB_nkl =
          mainloop_params.tma_load_b.get_tma_tensor(make_shape(N, K, L));
      return local_tile(mB_nkl, TileShape{}, make_coord(_, _, _),
                        Step<X, _1, _1>{});
    };

    // (BLK_M,BLK_Scale_K,m,scale_k,l)
    auto make_gS_mkl = [&]() {
      auto scale_k = mainloop_params.scale_k;
      Tensor mS_mkl = mainloop_params.tma_load_scale.get_tma_tensor(
          make_shape(M, scale_k, L));
      return local_tile(mS_mkl, ScaleTileShape{}, make_coord(_, _));
    };

    // (BLK_M,BLK_Scale_K,m,scale_k,l)
    auto make_gZ_mkl = [&]() {
      auto scale_k = mainloop_params.scale_k;
      Tensor mZ_mkl = mainloop_params.tma_load_zero.get_tma_tensor(
          make_shape(M, scale_k, L));
      return local_tile(mZ_mkl, ScaleTileShape{}, make_coord(_, _));
    };

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      return cute::make_tuple(make_gA_mkl(), make_gB_nkl());
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScale) {
      return cute::make_tuple(make_gA_mkl(), make_gB_nkl(), make_gS_mkl());
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScaleWithZero) {
      return cute::make_tuple(make_gA_mkl(), make_gB_nkl(), make_gS_mkl(),
                              make_gZ_mkl());
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in load_init.");
    }
  }

  /// Perform a collective-scoped matrix multiply-accumulate
  /// Producer Perspective
  /// This overload gets triggered when we have scales.
  template <class... Ts, class KTileIterator, class BlockCoord>
  CUTLASS_DEVICE void load(Params const& mainloop_params,
                           MainloopPipeline pipeline,
                           PipelineState smem_pipe_write,
                           cute::tuple<Ts...> const& load_inputs,
                           BlockCoord const& blk_coord,
                           KTileIterator k_tile_iter, int k_tile_count,
                           int thread_idx, uint32_t block_rank_in_cluster,
                           TensorStorage& shared_tensors) {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      static_assert(sizeof...(Ts) == 2, "Direct convert needs two inputs");
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScale) {
      static_assert(sizeof...(Ts) == 3, "Scaled convert needs three inputs");
    } else if constexpr (KernelConversionMode ==
                         ConversionMode::ConvertAndScaleWithZero) {
      static_assert(sizeof...(Ts) == 4,
                    "Scaled and zero convert needs four inputs");
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in TMA load.");
    }

    int lane_predicate = cute::elect_one_sync();

    if (lane_predicate) {
      Tensor sA_ = make_tensor(make_smem_ptr(shared_tensors.smem_A.begin()),
                               SmemLayoutA{});  // (BLK_M,BLK_K,PIPE)
      Tensor sB_ = make_tensor(make_smem_ptr(shared_tensors.smem_B.begin()),
                               SmemLayoutB{});  // (BLK_N,BLK_K,PIPE)
      Tensor sA =
          as_position_independent_swizzle_tensor(sA_);  // (BLK_M,BLK_K,PIPE)
      Tensor sB =
          as_position_independent_swizzle_tensor(sB_);  // (BLK_N,BLK_K,PIPE)

      //
      // Prepare the TMA loads for A, B and Scales
      //

      constexpr uint32_t cluster_shape_x = get<0>(ClusterShape());
      uint2 cluster_local_block_id = {block_rank_in_cluster % cluster_shape_x,
                                      block_rank_in_cluster / cluster_shape_x};

      Tensor gA_mkl = get<0>(load_inputs);
      Tensor gB_nkl = get<1>(load_inputs);

      auto block_tma_a =
          mainloop_params.tma_load_a.get_slice(cluster_local_block_id.y);
      auto block_tma_b =
          mainloop_params.tma_load_b.get_slice(cluster_local_block_id.x);

      // Partition the inputs based on the current block coordinates.
      auto [m_coord, n_coord, k_coord, l_coord] = blk_coord;
      Tensor gA = gA_mkl(_, _, m_coord, _, l_coord);  // (BLK_M,BLK_K,k)
      Tensor gB = gB_nkl(_, _, n_coord, _, l_coord);  // (BLK_N,BLK_K,k)

      // Applies the mapping from block_tma_a
      Tensor tAgA = block_tma_a.partition_S(gA);  // (TMA,TMA_M,TMA_K,k)
      Tensor tAsA = block_tma_a.partition_D(sA);  // (TMA,TMA_M,TMA_K,PIPE)

      Tensor tBgB = block_tma_b.partition_S(gB);  // (TMA,TMA_N,TMA_K,k)
      Tensor tBsB = block_tma_b.partition_D(sB);  // (TMA,TMA_N,TMA_K,PIPE)

      uint16_t mcast_mask_a = 0;
      uint16_t mcast_mask_b = 0;
      uint16_t mcast_mask_s = 0;

      // Issue TmaLoads
      // Maps the tile -> block, value
      if constexpr (cute::is_same_v<GmemTiledCopyA, SM90_TMA_LOAD_MULTICAST>) {
        auto block_layout =
            Layout<typename DispatchPolicy::ClusterShape>{};  // (m,n) ->
                                                              // block_id
        for (int n = 0; n < size<1>(block_layout); ++n) {
          mcast_mask_a |= (uint16_t(1) << block_layout(cluster_local_block_id.x,
                                                       n, Int<0>{}));
        }
      }

      if constexpr (cute::is_same_v<GmemTiledCopyB, SM90_TMA_LOAD_MULTICAST>) {
        auto block_layout =
            Layout<typename DispatchPolicy::ClusterShape>{};  // (m,n) ->
                                                              // block_id
        for (int m = 0; m < size<0>(block_layout); ++m) {
          mcast_mask_b |= (uint16_t(1) << block_layout(
                               m, cluster_local_block_id.y, Int<0>{}));
        }
      }

      auto extra_input_partitions = partition_extra_tma_inputs(
          mainloop_params, load_inputs, shared_tensors, cluster_local_block_id,
          m_coord, l_coord);

      // Mainloop
      CUTLASS_PRAGMA_NO_UNROLL
      for (; k_tile_count > 0; --k_tile_count) {
        // LOCK smem_pipe_write for _writing_
        pipeline.producer_acquire(smem_pipe_write);

        //
        // Copy gmem to smem for *k_tile_iter
        //

        using BarrierType = typename MainloopPipeline::ProducerBarrierType;
        BarrierType* tma_barrier =
            pipeline.producer_get_barrier(smem_pipe_write);

        int write_stage = smem_pipe_write.index();
        copy(mainloop_params.tma_load_a.with(*tma_barrier, mcast_mask_a),
             tAgA(_, _, _, *k_tile_iter), tAsA(_, _, _, write_stage));
        copy(mainloop_params.tma_load_b.with(*tma_barrier, mcast_mask_b),
             tBgB(_, _, _, *k_tile_iter), tBsB(_, _, _, write_stage));

        if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
          // Nothing extra to do.
        } else if constexpr (ModeHasScales) {
          auto tSgS = get<0>(extra_input_partitions);
          auto tSsS = get<1>(extra_input_partitions);

          // Temporary factor which will determine which k tile to reload from
          // gmem. Needed so we don't modify tma transaction bytes on the fly.
          // We must do a ceiling divide here to correctly handle with
          // group_size == K. In that case, we don't require that K is a
          // multiple of the threadblock tile K
          const int ReloadFactor =
              (mainloop_params.group_size + size<2>(TileShape{}) - 1) /
              size<2>(TileShape{});
          const int scale_load_k =
              *k_tile_iter /
              ReloadFactor;  // This will always be 0 when group_size == K.
          copy(mainloop_params.tma_load_scale.with(*tma_barrier, mcast_mask_s),
               tSgS(_, _, _, scale_load_k), tSsS(_, _, _, write_stage));

          if constexpr (KernelConversionMode ==
                        ConversionMode::ConvertAndScale) {
            // Nothing extra to do
          } else if constexpr (KernelConversionMode ==
                               ConversionMode::ConvertAndScaleWithZero) {
            auto tZgZ = get<2>(extra_input_partitions);
            auto tZsZ = get<3>(extra_input_partitions);
            copy(mainloop_params.tma_load_zero.with(*tma_barrier, mcast_mask_s),
                 tZgZ(_, _, _, scale_load_k), tZsZ(_, _, _, write_stage));
          } else {
            static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                          "Conversion mode not handled for TMA copy op.");
          }
        } else {
          static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                        "Conversion mode not handled for TMA copy op.");
        }

        ++k_tile_iter;

        // Advance smem_pipe_write
        ++smem_pipe_write;
      }
    }
  }

  /// Perform a Producer Epilogue to prevent early exit of blocks in a Cluster
  CUTLASS_DEVICE void load_tail(MainloopPipeline pipeline,
                                PipelineState smem_pipe_write) {
    int lane_predicate = cute::elect_one_sync();

    // Issue the epilogue waits
    if (lane_predicate) {
      /* This helps avoid early exit of blocks in Cluster
       * Waits for all stages to either be released (all
       * Consumer UNLOCKs), or if the stage was never used
       * then would just be acquired since the phase was
       * still inverted from make_producer_start_state
       */
      pipeline.producer_tail(smem_pipe_write);
    }
  }

  /// Perform a collective-scoped matrix multiply-accumulate
  /// Consumer Perspective
  template <class FrgTensorC>
  CUTLASS_DEVICE void mma(MainloopPipeline pipeline,
                          PipelineState smem_pipe_read, FrgTensorC& accum,
                          int k_tile_count, int thread_idx,
                          TensorStorage& shared_tensors,
                          Params const& mainloop_params) {
    static_assert(is_rmem<FrgTensorC>::value,
                  "C tensor must be rmem resident.");
    static_assert(cute::rank(SmemLayoutA{}) == 3,
                  "Smem layout must be rank 3.");
    static_assert(cute::rank(SmemLayoutB{}) == 3,
                  "Smem layout must be rank 3.");
    // static_assert(cute::rank(SmemLayoutAtomA{}) == 2, "SmemLayoutAtomA must
    // be rank 2.");
    static_assert(cute::rank(SmemLayoutAtomB{}) == 2,
                  "SmemLayoutAtomB must be rank 2.");
    static_assert(!cute::is_void_v<SmemCopyAtomA>,
                  "SM90 GMMA mainloops must specify a non-void copy atom for "
                  "RF sourced instructions.");
    static_assert(cute::is_void_v<SmemCopyAtomB>,
                  "SM90 GMMA mainloops cannot have a non-void copy atom for "
                  "smem sourced instructions.");

    // Obtain warp index
    int warp_idx = canonical_warp_idx_sync();
    [[maybe_unused]] int warp_group_thread_idx = thread_idx % 128;

    // ((T, (FrgV,(RestM, RestK)), (BlocksM, BlocksK), pipe) -> offset
    auto constexpr smem_A = SmemLayoutAPrepacked{};

    // convert:
    //   ((T, (MMA,(MMA_M, MMA_K)), (BlocksM, BlocksK), pipe) -> offset
    // to:
    //   (T, MMA, ((MMA_M, BlocksM), (MMA_K, BlocksK)), pipe) -> offset
    // which can be thought of as:
    //   (T, MMA, (MMA_M, MMA_K), pipe) -> offset
    auto constexpr smem_A_mma_ =
        make_layout(get<0, 0>(smem_A), get<0, 1, 0>(smem_A),
                    zip(get<0, 1, 1>(smem_A), get<1>(smem_A)), get<2>(smem_A));
    // flatten to:
    //   (T, MMA, MMA_M, MMA_K, pipe) -> offset
    auto constexpr smem_A_mma = smem_A_mma_(_, _, make_coord(_, _), _);

    Tensor sA_ = make_tensor(make_smem_ptr(shared_tensors.smem_A.begin()),
                             smem_A_mma);  // (T, MMA, MMA_M, MMA_K, pipe)
    Tensor sA = as_position_independent_swizzle_tensor(
        sA_);  // (T, MMA, MMA_M, MMA_K, pipe)

    Tensor sB = make_tensor(make_smem_ptr(shared_tensors.smem_B.begin()),
                            SmemLayoutB{});  // (BLK_N,BLK_K,PIPE)

    //
    // Define C accumulators and A/B partitioning
    //

    TiledMma tiled_mma;
    auto thread_mma = tiled_mma.get_thread_slice(thread_idx);

    Tensor tCsA = sA(thread_idx, _, _, _, _);  // (MMA,MMA_M,MMA_K,PIPE)
    Tensor tCsB = thread_mma.partition_B(sB);  // (MMA,MMA_N,MMA_K,PIPE)

    // Allocate fragments and descriptors
    Tensor tCrA_load = make_tensor<ElementA>(
        tCsA(_, _, _, Int<0>{}).shape());  // (MMA,MMA_N,MMA_K)
    Tensor tCrA_mma = make_fragment_like<ElementMma>(tCrA_load);

    Tensor tCrB = thread_mma.make_fragment_B(tCsB);  // (MMA,MMA_N,MMA_K,PIPE)

    static constexpr int A_CPY_VEC =
        decltype(max_common_vector(tCsA, tCrA_load)){};
    // static constexpr int K_BLOCKS_PER_COPY = size<0>(group<0, 2>(tCrA_load))
    // / A_CPY_VEC;
    static constexpr int COVERSION_WIDTH =
        std::min(A_CPY_VEC, int(size<0>(tCrA_mma)));

    auto load_A_to_registers = [&](int read_stage) {
      copy(AutoVectorizingCopyWithAssumedAlignment<A_CPY_VEC>{},
           tCsA(_, _, _, read_stage), tCrA_load(_, _, _));
    };

    // Partition of thread -> shared and thread -> RF
    auto partitioned_extra_info =
        partition_extra_mma_info(thread_mma, shared_tensors);
    auto copy_partitions_extra_info = retile_extra_mma_info(
        tiled_mma, partitioned_extra_info, warp_group_thread_idx);

    // CUTE_STATIC_ASSERT_V(size<1>(tCsA) == size<1>(tCrA_copy_view));     //
    // CPY_M CUTE_STATIC_ASSERT_V(size<2>(tCsA) == size<2>(tCrA_copy_view)); //
    // CPY_K
    CUTE_STATIC_ASSERT_V(size<1>(tCrA_mma) == size<1>(accum));  // MMA_M
    CUTE_STATIC_ASSERT_V(size<1>(tCsB) == size<2>(accum));      // N
    CUTE_STATIC_ASSERT_V(size<2>(tCsA) == size<2>(tCsB));       // K
    CUTE_STATIC_ASSERT_V(size<3>(tCsA) == size<3>(tCsB));       // PIPE
    // CUTE_STATIC_ASSERT_V(Int<DispatchPolicy::Stages>{} == size<2>(sA)); //
    // PIPE
    CUTE_STATIC_ASSERT_V(Int<DispatchPolicy::Stages>{} == size<2>(sB));  // PIPE

    //
    // PIPELINED MAIN LOOP
    //

    auto convert_A = [&, a_vec = Int<COVERSION_WIDTH>{}](int k_block,
                                                         int read_stage) {
      load_extra_info_to_registers(partitioned_extra_info,
                                   copy_partitions_extra_info, k_block,
                                   read_stage);
      transform_A_kblock(tCrA_load, a_vec, tCrA_mma, partitioned_extra_info,
                         k_block);
    };

    // We release buffers to producer warps(dma load) with some mmas in flight
    PipelineState smem_pipe_release = smem_pipe_read;

    tiled_mma.accumulate_ = GMMA::ScaleOut::Zero;

    TransposeOperandB transpose =
        transform::collective::detail::make_transpose_operand_b(
            warp_idx, warp_group_thread_idx, tiled_mma, SmemLayoutB{},
            SmemLayoutAtomB{}, InternalElementB{},
            cute::bool_constant<TransposeB>{});

    warpgroup_fence_operand(accum);

    constexpr int K_BLOCK_MAX = size<2>(tCrA_load);

    ConsumerToken barrier_token = {BarrierStatus::WaitAgain};
    // first k tile
    {
      barrier_token = pipeline.consumer_try_wait(smem_pipe_read);
      pipeline.consumer_wait(smem_pipe_read, barrier_token);

      int read_stage = smem_pipe_read.index();

      ++smem_pipe_read;
      barrier_token = pipeline.consumer_try_wait(smem_pipe_read);

      // copy smem->rmem for A operand
      load_A_to_registers(read_stage);
      convert_A(0, read_stage);

      // Unroll the K mode manually to set scale D to 1
      CUTLASS_PRAGMA_UNROLL
      for (int k_block = 0; k_block < K_BLOCK_MAX; ++k_block) {
        if (k_block < K_BLOCK_MAX - 1) {
          convert_A(k_block + 1, smem_pipe_read.index());
        }
        warpgroup_arrive();
        // (V,M) x (V,N) => (V,M,N)
        cute::gemm(tiled_mma, tCrA_mma(_, _, k_block),
                   tCrB(_, _, k_block, read_stage), accum);
        tiled_mma.accumulate_ = GMMA::ScaleOut::One;
        warpgroup_commit_batch();
      }

      --k_tile_count;
      if (k_tile_count > 0) {
        // Wait for K_BLOCK_MAX - 1 to be in flight to ensure that it is safe to
        // overwrite the A registers for the first mma.
        warpgroup_wait<K_BLOCK_MAX - 1>();
        pipeline.consumer_wait(smem_pipe_read, barrier_token);
        load_A_to_registers(smem_pipe_read.index());
        convert_A(0, smem_pipe_read.index());
      }
    }

    if (k_tile_count == 0) {
      return;
    }

    warpgroup_fence_operand(accum);
    // Mainloop GMMAs
    CUTLASS_PRAGMA_NO_UNROLL
    for (; k_tile_count > 1; --k_tile_count) {
      //
      // Compute on k_tile
      //

      int read_stage = smem_pipe_read.index();
      ++smem_pipe_read;

      warpgroup_fence_operand(accum);
      // Unroll the K mode manually to set scale D to 1
      CUTLASS_PRAGMA_UNROLL
      for (int k_block = 0; k_block < K_BLOCK_MAX; ++k_block) {
        warpgroup_arrive();
        // (V,M) x (V,N) => (V,M,N)
        cute::gemm(tiled_mma, tCrA_mma(_, _, k_block),
                   tCrB(_, _, k_block, read_stage), accum);
        tiled_mma.accumulate_ = GMMA::ScaleOut::One;
        warpgroup_commit_batch();

        warpgroup_wait<K_BLOCK_MAX - 1>();
        if (k_block == K_BLOCK_MAX - 1) {
          // We have K_BLOCK_MAX - 1 GMMA instructions pending for this stage,
          // so we can release prior barrier
          pipeline.consumer_release(
              smem_pipe_release);  // UNLOCK smem_pipe_release, done _computing_
                                   // on it
          ++smem_pipe_release;
        }

        if (k_block == 0) {
          barrier_token = pipeline.consumer_try_wait(smem_pipe_read);
        }

        if (k_block == K_BLOCK_MAX - 1) {
          pipeline.consumer_wait(smem_pipe_read, barrier_token);
          load_A_to_registers(smem_pipe_read.index());
          convert_A(0, smem_pipe_read.index());
        } else {
          convert_A(k_block + 1, read_stage);
        }
      }
      warpgroup_fence_operand(accum);
    }

    warpgroup_fence_operand(accum);

    {
      //
      // Compute on k_tile
      //

      int read_stage = smem_pipe_read.index();

      warpgroup_fence_operand(accum);

      // Unroll the K mode manually to set scale D to 1
      CUTLASS_PRAGMA_UNROLL
      for (int k_block = 0; k_block < K_BLOCK_MAX; ++k_block) {
        warpgroup_arrive();
        // (V,M) x (V,N) => (V,M,N)
        cute::gemm(tiled_mma, tCrA_mma(_, _, k_block),
                   tCrB(_, _, k_block, read_stage), accum);
        tiled_mma.accumulate_ = GMMA::ScaleOut::One;
        warpgroup_commit_batch();
        warpgroup_wait<K_BLOCK_MAX - 1>();
        if (k_block == K_BLOCK_MAX - 1) {
          // release prior barrier
          pipeline.consumer_release(
              smem_pipe_release);  // UNLOCK smem_pipe_release, done _computing_
                                   // on it
          ++smem_pipe_release;
        }

        if (k_block < K_BLOCK_MAX - 1) {
          convert_A(k_block + 1, read_stage);
        }
      }
    }

    warpgroup_fence_operand(accum);
  }

  /// Perform a Consumer Epilogue to release all buffers
  CUTLASS_DEVICE void mma_tail(MainloopPipeline pipeline,
                               PipelineState smem_pipe_release,
                               int k_tile_count) {
    // Prologue GMMAs
    int prologue_mma_count = 1;
    k_tile_count -= prologue_mma_count;

    smem_pipe_release.advance(k_tile_count);

    // Wait on all GMMAs to complete
    warpgroup_wait<0>();

    for (int count = 0; count < prologue_mma_count; ++count) {
      pipeline.consumer_release(
          smem_pipe_release);  // UNLOCK smem_pipe_release, done _computing_ on
                               // it
      ++smem_pipe_release;
    }
  }

 private:
  /// Utilities for any additional inputs inside of the TMA load
  template <class... Ts>
  CUTLASS_DEVICE auto partition_extra_tma_inputs(
      Params const& mainloop_params, cute::tuple<Ts...> const& load_inputs,
      TensorStorage& shared_tensors, uint2 const& cluster_local_block_id,
      int const m_coord, int const l_coord) {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      return cute::tuple{};
    } else if constexpr (ModeHasScales) {
      Tensor sS = make_tensor(make_smem_ptr(shared_tensors.smem_scale.begin()),
                              SmemLayoutScale{});  // (BLK_M,BLK_K,PIPE)
      Tensor gS_mkl = get<2>(load_inputs);
      auto block_tma_s =
          mainloop_params.tma_load_scale.get_slice(cluster_local_block_id.y);
      Tensor gS = gS_mkl(_, _, m_coord, _, l_coord);  // (BLK_M,BLK_K,k)

      Tensor tSgS = block_tma_s.partition_S(gS);  // (TMA,TMA_M,TMA_K,k)
      Tensor tSsS = block_tma_s.partition_D(sS);  // (TMA,TMA_M,TMA_K,PIPE)
      if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
        return cute::make_tuple(tSgS, tSsS);
      } else if constexpr (KernelConversionMode ==
                           ConversionMode::ConvertAndScaleWithZero) {
        Tensor sZ = make_tensor(make_smem_ptr(shared_tensors.smem_zero.begin()),
                                SmemLayoutScale{});  // (BLK_M,BLK_K,PIPE)
        Tensor gZ_mkl = get<3>(load_inputs);
        auto block_tma_z =
            mainloop_params.tma_load_zero.get_slice(cluster_local_block_id.y);
        Tensor gZ = gZ_mkl(_, _, m_coord, _, l_coord);  // (BLK_M,BLK_K,k)

        Tensor tZgZ = block_tma_z.partition_S(gZ);  // (TMA,TMA_M,TMA_K,k)
        Tensor tZsZ = block_tma_z.partition_D(sZ);  // (TMA,TMA_M,TMA_K,PIPE)
        return cute::make_tuple(tSgS, tSsS, tZgZ, tZsZ);
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Conversion mode not handled for input partitioning.");
      }
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled for input partitioning.");
    }
  }

  /// Utilities for partitioning extra inputs for loading from smem in the
  /// mainloop.
  template <class ThreadMma>
  CUTLASS_DEVICE auto partition_extra_mma_info(ThreadMma const& thread_mma,
                                               TensorStorage& shared_tensors) {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      // noting to do
      return cute::tuple{};
    } else if constexpr (ModeHasScales) {
      Tensor sS = make_tensor(make_smem_ptr(shared_tensors.smem_scale.begin()),
                              SmemLayoutScale{});  // (BLK_M,BLK_SCALE_K,PIPE)
      Tensor tCsS = thread_mma.partition_A(sS);
      Tensor tCrS = make_tensor<ElementScale>(
          thread_mma.partition_fragment_A(sS(_, _, Int<0>{})).shape());

      if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
        return cute::make_tuple(tCsS, tCrS);
      } else if constexpr (KernelConversionMode ==
                           ConversionMode::ConvertAndScaleWithZero) {
        Tensor sZ = make_tensor(make_smem_ptr(shared_tensors.smem_zero.begin()),
                                SmemLayoutScale{});  // (BLK_M,BLK_SCALE_K,PIPE)
        Tensor tCsZ = thread_mma.partition_A(sZ);
        Tensor tCrZ = make_tensor<ElementZero>(
            thread_mma.partition_fragment_A(sZ(_, _, Int<0>{})).shape());
        return cute::make_tuple(tCsS, tCrS, tCsZ, tCrZ);
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Conversion mode not handled in A -> RF path.");
      }
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in A -> RF path.");
    }
  }

  /// Returns the tiled copy and copy views for the extra inputs.
  template <class TiledMma, class... Ts>
  CUTLASS_DEVICE auto retile_extra_mma_info(
      TiledMma const& tiled_mma, cute::tuple<Ts...>& partitioned_extra_info,
      int const warp_group_thread_idx) {
    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      // noting to do
      return cute::tuple{};
    } else if constexpr (ModeHasScales) {
      auto smem_tiled_copy_S =
          make_tiled_copy_A(SmemCopyAtomScale{}, tiled_mma);
      auto smem_thr_copy_S =
          smem_tiled_copy_S.get_thread_slice(warp_group_thread_idx);
      Tensor tCrS_copy_view = smem_thr_copy_S.retile_D(
          cute::get<1>(partitioned_extra_info));  // (CPY,CPY_M,CPY_K)

      if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
        return cute::make_tuple(smem_tiled_copy_S, tCrS_copy_view);
      } else if constexpr (KernelConversionMode ==
                           ConversionMode::ConvertAndScaleWithZero) {
        Tensor tCrZ_copy_view = smem_thr_copy_S.retile_D(
            cute::get<3>(partitioned_extra_info));  // (CPY,CPY_M,CPY_K)
        return cute::make_tuple(smem_tiled_copy_S, tCrS_copy_view,
                                tCrZ_copy_view);
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Conversion mode not handled in A -> RF path.");
      }
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "Conversion mode not handled in A -> RF path.");
    }
  }

  /// Utilities to copy A and extra inputs from smem to RF
  template <class... Ts, class... Us>
  CUTLASS_DEVICE void load_extra_info_to_registers(
      cute::tuple<Ts...> const& partitioned_mma_extra_info,
      cute::tuple<Us...> const& tiled_copy_and_views, int k_block,
      int read_stage) {
    if (k_block == 0) {
      // We are starting a new k-tile so copy the scale
      if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
        // nothing to do
      } else if constexpr (ModeHasScales) {
        auto smem_tiled_copy_S = cute::get<0>(tiled_copy_and_views);
        auto tCrS_copy_view = cute::get<1>(tiled_copy_and_views);
        auto tCsS = cute::get<0>(partitioned_mma_extra_info);
        copy(smem_tiled_copy_S, tCsS(_, _, k_block, read_stage),
             tCrS_copy_view(_, _, k_block));
        if constexpr (KernelConversionMode == ConversionMode::ConvertAndScale) {
          // Nothing extra to do
        } else if constexpr (KernelConversionMode ==
                             ConversionMode::ConvertAndScaleWithZero) {
          auto tCsZ = cute::get<2>(partitioned_mma_extra_info);
          auto tCrZ_copy_view = cute::get<2>(tiled_copy_and_views);
          copy(smem_tiled_copy_S, tCsZ(_, _, k_block, read_stage),
               tCrZ_copy_view(_, _, k_block));
        } else {
          static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                        "Conversion mode not handled in A -> RF path.");
        }
      } else {
        static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                      "Conversion mode not handled in A -> RF path.");
      }
    }
  }

  /// Utilities to transform A.
  template <class TCrA_load, int VectorWidthA, class TCrA_mma, class... Ts>
  CUTLASS_DEVICE void transform_A_kblock(
      TCrA_load const& tCrA_load, cute::Int<VectorWidthA> vec_A,
      TCrA_mma& tCrA_mma, cute::tuple<Ts...> const& partitioned_extra_info,
      int const k_block) {
    auto in = tCrA_load(_, _, k_block);
    auto out = tCrA_mma(_, _, k_block);

    if constexpr (KernelConversionMode == ConversionMode::DirectConvert) {
      convert_tensor(in, out, vec_A);
    } else if constexpr (ModeHasScales) {
      auto tCrS = cute::get<1>(partitioned_extra_info);
      auto converted_inputs =
          make_fragment_like<ElementScale>(tCrA_mma)(_, _, k_block);
      auto scales = tCrS(_, _, 0);

      // First, we upcast the inputs to the scale type
      convert_tensor(in, converted_inputs, vec_A);
      // Apply scales and broadcast across inputs, store in converted_inputs
      cute::transform(converted_inputs, scales, converted_inputs,
                      cute::multiplies{});

      // Apply zeros if required
      if constexpr (KernelConversionMode ==
                    ConversionMode::ConvertAndScaleWithZero) {
        auto tCrZ = cute::get<3>(partitioned_extra_info);
        auto converted_zeros = make_fragment_like<ElementScale>(tCrZ)(_, _, 0);

        convert_tensor(tCrZ(_, _, 0), converted_zeros);
        cute::transform(converted_inputs, converted_zeros, converted_inputs,
                        cute::plus{});
      }

      // Finally, we convert the scaled inputs to the mma type.
      convert_tensor(converted_inputs, out);
    } else {
      static_assert(cutlass::detail::dependent_false<KernelSchedule>,
                    "No A data is loaded.");
    }
  }

  /// Utilities for transforming the A operand prior to issuing tensorcore math.
  template <class EngineIn, class EngineOut, class TensorLayout,
            int ConversionVectorWidth = cosize_v<TensorLayout>>
  CUTLASS_DEVICE void convert_tensor(
      Tensor<EngineIn, TensorLayout> const& in,
      Tensor<EngineOut, TensorLayout>& out,
      cute::Int<ConversionVectorWidth> width = {}) {
    /// This is an element-wise conversion where we expect both tensors to have
    /// the same layout. As a result, we can cast as a cutlass array to use the
    /// fast numeric converters without worrying about indexing into the layout.
    constexpr int N = cosize_v<TensorLayout>;

    /// The inputs must be backed by registers & be statically sized.
    static_assert(is_rmem<EngineIn>::value,
                  "Input tensor for A conversion must come from registers");
    static_assert(is_rmem<EngineOut>::value,
                  "Output tensor for A conversion must come from registers");
    static_assert(is_static_v<TensorLayout>,
                  "Tensor layout for the conversion must be static");
    static_assert(cosize_v<TensorLayout> == size(TensorLayout{}),
                  "Cosize and size of the layout must be equal.");
    static_assert(
        N % ConversionVectorWidth == 0,
        "Conversion vector width must divide cosize of the tensor layout.");

    using SrcType = typename EngineIn::value_type;
    using DstType = typename EngineOut::value_type;

    using SrcArray = cutlass::Array<SrcType, ConversionVectorWidth>;
    using DstArray = cutlass::Array<DstType, ConversionVectorWidth>;

    constexpr cutlass::FloatRoundStyle RoundStyle =
        cutlass::FloatRoundStyle::round_to_nearest;
    using Converter =
        cutlass::NumericArrayConverter<DstType, SrcType, ConversionVectorWidth,
                                       RoundStyle>;

    constexpr int NumIterations = N / ConversionVectorWidth;

    for (int ii = 0; ii < NumIterations; ++ii) {
      SrcArray const* src_array_ptr =
          reinterpret_cast<SrcArray const*>(raw_pointer_cast(in.data())) + ii;
      DstArray* dst_array_ptr =
          reinterpret_cast<DstArray*>(raw_pointer_cast(out.data())) + ii;
      *dst_array_ptr = Converter::convert(*src_array_ptr);
    }
  }
};

/////////////////////////////////////////////////////////////////////////////////////////////////

}  // namespace marlinv2

/////////////////////////////////////////////////////////////////////////////////////////////////
