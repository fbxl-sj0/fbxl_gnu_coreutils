/*
    Project: GNU Coreutils FreeBASIC port
    ------------------------------------

    File: arm_stubs/arm_neon.h

    Purpose:

        Supply enough ARM NEON declarations for C2FB to read the optional
        ARM checksum and wc sources on this non-ARM build host.

    Responsibilities:

        • describe the vector types referenced by the two source files
        • declare the intrinsic names used in bodies replaced by scalar FBC code

    This file intentionally does NOT contain:

        • ARM intrinsic implementations or executable fallback behavior
        • declarations for general ARM applications
*/

#ifndef COREUTILS_C2FB_ARM_NEON_STUB_H
#define COREUTILS_C2FB_ARM_NEON_STUB_H

#include <stdint.h>

typedef struct { uint64_t lane[2]; } uint64x2_t;
typedef uint64_t uint64x1_t;
typedef struct { uint64_t lane[2]; } poly64x2_t;
typedef uint64_t poly64_t;
typedef struct { uint64_t lane[2]; } poly128_t;
typedef struct { uint8_t lane[16]; } uint8x16_t;
typedef struct { int8_t lane[16]; } int8x16_t;
typedef struct { int16_t lane[8]; } int16x8_t;
typedef struct { int32_t lane[4]; } int32x4_t;
typedef struct { int64_t lane[2]; } int64x2_t;

uint64x2_t vdupq_n_u64 (uint64_t value);
uint64x1_t vcreate_u64 (uint64_t value);
poly64_t vcreate_p64 (uint64_t value);
uint64x2_t vcombine_u64 (uint64x1_t low, uint64x1_t high);
poly64x2_t vcombine_p64 (poly64_t low, poly64_t high);
uint64x1_t vget_low_u64 (uint64x2_t value);
uint64x1_t vget_high_u64 (uint64x2_t value);
uint8x16_t vrev64q_u8 (uint8x16_t value);
uint8x16_t vreinterpretq_u8_u64 (uint64x2_t value);
uint64x2_t vreinterpretq_u64_u8 (uint8x16_t value);
poly64x2_t vreinterpretq_p64_u64 (uint64x2_t value);
poly128_t vmull_p64 (poly64_t left, poly64_t right);
poly128_t vmull_high_p64 (poly64x2_t left, poly64x2_t right);
poly64_t vgetq_lane_p64 (poly64x2_t value, int lane);
uint64x2_t vreinterpretq_u64_p128 (poly128_t value);
uint64x2_t vld1q_u64 (const uint64_t *address);
uint8x16_t vld1q_u8 (const uint8_t *address);
void vst1q_u64 (uint64_t *address, uint64x2_t value);
uint64x2_t veorq_u64 (uint64x2_t left, uint64x2_t right);
uint8x16_t vdupq_n_u8 (uint8_t value);
int8x16_t vdupq_n_s8 (int8_t value);
int8x16_t vreinterpretq_s8_u8 (uint8x16_t value);
uint8x16_t vceqq_u8 (uint8x16_t left, uint8x16_t right);
int8x16_t vaddq_s8 (int8x16_t left, int8x16_t right);
int16x8_t vpaddlq_s8 (int8x16_t value);
int32x4_t vpaddlq_s16 (int16x8_t value);
int64x2_t vpaddlq_s32 (int32x4_t value);
int64_t vgetq_lane_s64 (int64x2_t value, int lane);

#endif

/* end of arm_stubs/arm_neon.h */
