/*
    Project: GNU Coreutils FreeBASIC port

    File: arm_neon.h

    Purpose:

        Provide a scalar C representation of the NEON operations used by
        src/wc_neon.c so C2FB can translate the unchanged command algorithm.

    Responsibilities:

        - Preserve the 16-byte lane layout of the vector values used by wc.
        - Implement the small set of load, compare, add, pairwise-sum, and
          lane-extract operations used by wc_lines_neon.

    This file intentionally does NOT contain:

        - Hardware-specific NEON intrinsics or assembly.
        - Intrinsics outside the wc_neon source profile.
*/

#ifndef C2FB_COREUTILS_WC_NEON_SCALAR_ARM_NEON_H
#define C2FB_COREUTILS_WC_NEON_SCALAR_ARM_NEON_H

#include <stdint.h>

typedef struct { uint8_t lane[16]; } uint8x16_t;
typedef struct { int8_t lane[16]; } int8x16_t;
typedef struct { int16_t lane[8]; } int16x8_t;
typedef struct { int32_t lane[4]; } int32x4_t;
typedef struct { int64_t lane[2]; } int64x2_t;

static inline uint8x16_t
vdupq_n_u8 (uint8_t value)
{
  uint8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    result.lane[lane] = value;
  return result;
}

static inline int8x16_t
vdupq_n_s8 (int8_t value)
{
  int8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    result.lane[lane] = value;
  return result;
}

static inline uint8x16_t
vld1q_u8 (const uint8_t *source)
{
  uint8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    result.lane[lane] = source[lane];
  return result;
}

static inline uint8x16_t
vceqq_u8 (uint8x16_t left, uint8x16_t right)
{
  uint8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    result.lane[lane] = left.lane[lane] == right.lane[lane] ? UINT8_MAX : 0;
  return result;
}

static inline int8x16_t
vreinterpretq_s8_u8 (uint8x16_t value)
{
  int8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    {
      int16_t signed_value = value.lane[lane];
      if (signed_value >= 128)
        signed_value -= 256;
      result.lane[lane] = (int8_t) signed_value;
    }
  return result;
}

static inline int8x16_t
vaddq_s8 (int8x16_t left, int8x16_t right)
{
  int8x16_t result;
  for (int lane = 0; lane < 16; lane++)
    {
      uint8_t bits = (uint8_t) ((int16_t) left.lane[lane]
                                + (int16_t) right.lane[lane]);
      int16_t signed_value = bits;
      if (signed_value >= 128)
        signed_value -= 256;
      result.lane[lane] = (int8_t) signed_value;
    }
  return result;
}

static inline int16x8_t
vpaddlq_s8 (int8x16_t value)
{
  int16x8_t result;
  for (int lane = 0; lane < 8; lane++)
    result.lane[lane] = (int16_t) value.lane[2 * lane]
                        + (int16_t) value.lane[2 * lane + 1];
  return result;
}

static inline int32x4_t
vpaddlq_s16 (int16x8_t value)
{
  int32x4_t result;
  for (int lane = 0; lane < 4; lane++)
    result.lane[lane] = (int32_t) value.lane[2 * lane]
                        + (int32_t) value.lane[2 * lane + 1];
  return result;
}

static inline int64x2_t
vpaddlq_s32 (int32x4_t value)
{
  int64x2_t result;
  for (int lane = 0; lane < 2; lane++)
    result.lane[lane] = (int64_t) value.lane[2 * lane]
                        + (int64_t) value.lane[2 * lane + 1];
  return result;
}

static inline int64_t
vgetq_lane_s64 (int64x2_t value, int lane)
{
  if (lane < 0 || lane >= 2)
    return 0;
  return value.lane[lane];
}

#endif

/* end of arm_neon.h */
