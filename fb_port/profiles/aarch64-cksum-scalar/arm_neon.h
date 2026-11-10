/*
    Project: GNU Coreutils FreeBASIC port

    File: arm_neon.h

    Purpose:

        Represent the ARM polynomial and vector operations used by
        src/cksum_vmull.c with scalar C helpers that C2FB can translate.

    Responsibilities:

        - Preserve the two-lane, 128-bit layouts used by the checksum source.
        - Implement byte reversal, lane access, XOR, and carryless polynomial
          multiplication with defined unsigned arithmetic.

    This file intentionally does NOT contain:

        - Hardware-specific NEON instructions or assembly.
        - Intrinsics outside the cksum_vmull source profile.
*/

#ifndef C2FB_COREUTILS_CKSUM_SCALAR_ARM_NEON_H
#define C2FB_COREUTILS_CKSUM_SCALAR_ARM_NEON_H

#include <stdint.h>

typedef struct { uint64_t lane[2]; } uint64x2_t;
typedef uint64_t uint64x1_t;
typedef struct { uint64_t lane[2]; } poly64x2_t;
typedef uint64_t poly64_t;
typedef struct { uint64_t lane[2]; } poly128_t;
typedef struct { uint8_t lane[16]; } uint8x16_t;

static inline uint64x1_t
vcreate_u64 (uint64_t value)
{
  return value;
}

static inline poly64_t
vcreate_p64 (uint64_t value)
{
  return value;
}

static inline uint64x2_t
vcombine_u64 (uint64x1_t low, uint64x1_t high)
{
  uint64x2_t result;
  result.lane[0] = low;
  result.lane[1] = high;
  return result;
}

static inline poly64x2_t
vcombine_p64 (poly64_t low, poly64_t high)
{
  poly64x2_t result;
  result.lane[0] = low;
  result.lane[1] = high;
  return result;
}

static inline uint64x1_t
vget_low_u64 (uint64x2_t value)
{
  return value.lane[0];
}

static inline uint64x1_t
vget_high_u64 (uint64x2_t value)
{
  return value.lane[1];
}

static inline uint8x16_t
vreinterpretq_u8_u64 (uint64x2_t value)
{
  uint8x16_t result;
  for (int lane = 0; lane < 2; lane++)
    for (int byte = 0; byte < 8; byte++)
      result.lane[lane * 8 + byte] =
        (uint8_t) (value.lane[lane] >> (byte * 8));
  return result;
}

static inline uint64x2_t
vreinterpretq_u64_u8 (uint8x16_t value)
{
  uint64x2_t result;
  for (int lane = 0; lane < 2; lane++)
    {
      uint64_t word = 0;
      for (int byte = 0; byte < 8; byte++)
        word |= (uint64_t) value.lane[lane * 8 + byte] << (byte * 8);
      result.lane[lane] = word;
    }
  return result;
}

static inline uint8x16_t
vrev64q_u8 (uint8x16_t value)
{
  uint8x16_t result;
  for (int lane = 0; lane < 2; lane++)
    for (int byte = 0; byte < 8; byte++)
      result.lane[lane * 8 + byte] = value.lane[lane * 8 + 7 - byte];
  return result;
}

static inline poly64x2_t
vreinterpretq_p64_u64 (uint64x2_t value)
{
  poly64x2_t result;
  result.lane[0] = value.lane[0];
  result.lane[1] = value.lane[1];
  return result;
}

static inline poly128_t
vmull_p64 (poly64_t left, poly64_t right)
{
  poly128_t result;
  result.lane[0] = 0;
  result.lane[1] = 0;
  for (int bit = 0; bit < 64; bit++)
    if (((right >> bit) & 1) != 0)
      {
        if (bit == 0)
          result.lane[0] ^= left;
        else
          {
            result.lane[0] ^= left << bit;
            result.lane[1] ^= left >> (64 - bit);
          }
      }
  return result;
}

static inline poly128_t
vmull_high_p64 (poly64x2_t left, poly64x2_t right)
{
  return vmull_p64 (left.lane[1], right.lane[1]);
}

static inline poly64_t
vgetq_lane_p64 (poly64x2_t value, int lane)
{
  if (lane < 0 || lane >= 2)
    return 0;
  return value.lane[lane];
}

static inline uint64x2_t
vreinterpretq_u64_p128 (poly128_t value)
{
  uint64x2_t result;
  result.lane[0] = value.lane[0];
  result.lane[1] = value.lane[1];
  return result;
}

static inline uint64x2_t
vld1q_u64 (const uint64_t *address)
{
  uint64x2_t result;
  result.lane[0] = address[0];
  result.lane[1] = address[1];
  return result;
}

static inline void
vst1q_u64 (uint64_t *address, uint64x2_t value)
{
  address[0] = value.lane[0];
  address[1] = value.lane[1];
}

static inline uint64x2_t
veorq_u64 (uint64x2_t left, uint64x2_t right)
{
  uint64x2_t result;
  result.lane[0] = left.lane[0] ^ right.lane[0];
  result.lane[1] = left.lane[1] ^ right.lane[1];
  return result;
}

#endif

/* end of arm_neon.h */
