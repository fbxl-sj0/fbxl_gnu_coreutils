/*
    Project: GNU Coreutils FreeBASIC port
    File: x86intrin.h

    Purpose:

        Provide a C2FB-compatible representation of the AVX2 operations used
        by src/cksum_avx2.c and src/wc_avx2.c.

    Responsibilities:

        - Describe each 256-bit value as 32 byte-addressable bytes.
        - Preserve AVX2 constructors, loads, stores, comparisons, byte
          shuffles, XOR, movemask, and PCLMUL semantics in small C helpers
          that C2FB translates to FreeBASIC.
        - Prevent the host GCC intrinsic header from replacing this projection
          in the C2FB-only preprocessing context.

    This file intentionally does NOT contain:

        - CPU feature detection or dispatch.
        - The checksum and line-counting algorithms in the source files.
        - The native C reference used by runtime comparisons.
*/
#ifndef COREUTILS_C2FB_AVX2_INTRINSICS_H
#define COREUTILS_C2FB_AVX2_INTRINSICS_H 1

/* The header forced into C2FB's generic-header pass precedes source includes. */
#ifndef _X86INTRIN_H_INCLUDED
#define _X86INTRIN_H_INCLUDED 1
#endif

typedef struct avx2_vector256
{
  unsigned char bytes[32];
} __m256i;
typedef __m256i __m256i_u;

/* ------------------------------------------------------------------------- */
/* AVX2 constructors                                                         */
/* ------------------------------------------------------------------------- */

static inline __m256i
_mm256_set_epi64x (long long e3, long long e2, long long e1, long long e0)
{
  __m256i result;
  unsigned long long words[4];
  words[0] = (unsigned long long) e0;
  words[1] = (unsigned long long) e1;
  words[2] = (unsigned long long) e2;
  words[3] = (unsigned long long) e3;
  for (int lane = 0; lane < 4; lane++)
    for (int byte = 0; byte < 8; byte++)
      result.bytes[lane * 8 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

static inline __m256i
_mm256_set_epi8 (
    char e31, char e30, char e29, char e28, char e27, char e26, char e25,
    char e24, char e23, char e22, char e21, char e20, char e19, char e18,
    char e17, char e16, char e15, char e14, char e13, char e12, char e11,
    char e10, char e9, char e8, char e7, char e6, char e5, char e4, char e3,
    char e2, char e1, char e0)
{
  __m256i result;
  result.bytes[0] = (unsigned char) e0;
  result.bytes[1] = (unsigned char) e1;
  result.bytes[2] = (unsigned char) e2;
  result.bytes[3] = (unsigned char) e3;
  result.bytes[4] = (unsigned char) e4;
  result.bytes[5] = (unsigned char) e5;
  result.bytes[6] = (unsigned char) e6;
  result.bytes[7] = (unsigned char) e7;
  result.bytes[8] = (unsigned char) e8;
  result.bytes[9] = (unsigned char) e9;
  result.bytes[10] = (unsigned char) e10;
  result.bytes[11] = (unsigned char) e11;
  result.bytes[12] = (unsigned char) e12;
  result.bytes[13] = (unsigned char) e13;
  result.bytes[14] = (unsigned char) e14;
  result.bytes[15] = (unsigned char) e15;
  result.bytes[16] = (unsigned char) e16;
  result.bytes[17] = (unsigned char) e17;
  result.bytes[18] = (unsigned char) e18;
  result.bytes[19] = (unsigned char) e19;
  result.bytes[20] = (unsigned char) e20;
  result.bytes[21] = (unsigned char) e21;
  result.bytes[22] = (unsigned char) e22;
  result.bytes[23] = (unsigned char) e23;
  result.bytes[24] = (unsigned char) e24;
  result.bytes[25] = (unsigned char) e25;
  result.bytes[26] = (unsigned char) e26;
  result.bytes[27] = (unsigned char) e27;
  result.bytes[28] = (unsigned char) e28;
  result.bytes[29] = (unsigned char) e29;
  result.bytes[30] = (unsigned char) e30;
  result.bytes[31] = (unsigned char) e31;
  return result;
}

static inline __m256i
_mm256_set_epi32 (int e7, int e6, int e5, int e4,
                  int e3, int e2, int e1, int e0)
{
  __m256i result;
  unsigned int words[8];
  words[0] = (unsigned int) e0;
  words[1] = (unsigned int) e1;
  words[2] = (unsigned int) e2;
  words[3] = (unsigned int) e3;
  words[4] = (unsigned int) e4;
  words[5] = (unsigned int) e5;
  words[6] = (unsigned int) e6;
  words[7] = (unsigned int) e7;
  for (int lane = 0; lane < 8; lane++)
    for (int byte = 0; byte < 4; byte++)
      result.bytes[lane * 4 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

static inline __m256i
_mm256_set1_epi8 (char value)
{
  __m256i result;
  for (int byte = 0; byte < 32; byte++)
    result.bytes[byte] = (unsigned char) value;
  return result;
}

/* ------------------------------------------------------------------------- */
/* Loads, stores, shuffle, and XOR                                            */
/* ------------------------------------------------------------------------- */

static inline __m256i
_mm256_loadu_si256 (const __m256i_u *source)
{
  return *source;
}

static inline __m256i
_mm256_load_si256 (const __m256i_u *source)
{
  return *source;
}

static inline void
_mm256_storeu_si256 (__m256i_u *destination, __m256i value)
{
  *destination = value;
}

static inline __m256i
_mm256_xor_si256 (__m256i left, __m256i right)
{
  __m256i result;
  for (int byte = 0; byte < 32; byte++)
    result.bytes[byte] = left.bytes[byte] ^ right.bytes[byte];
  return result;
}

static inline __m256i
_mm256_cmpeq_epi8 (__m256i left, __m256i right)
{
  __m256i result;
  for (int byte = 0; byte < 32; byte++)
    result.bytes[byte] = left.bytes[byte] == right.bytes[byte] ? 0xff : 0;
  return result;
}

static inline int
_mm256_movemask_epi8 (__m256i value)
{
  unsigned int mask = 0;
  for (int byte = 0; byte < 32; byte++)
    if ((value.bytes[byte] & 0x80) != 0)
      mask |= 1U << byte;
  return (int) mask;
}

static inline __m256i
_mm256_shuffle_epi8 (__m256i value, __m256i indices)
{
  __m256i result;
  for (int byte = 0; byte < 32; byte++)
    {
      unsigned char control = indices.bytes[byte];
      if ((control & 0x80) != 0)
        result.bytes[byte] = 0;
      else
        result.bytes[byte] =
          value.bytes[(byte & 16) + (control & 0x0f)];
    }
  return result;
}

/* ------------------------------------------------------------------------- */
/* PCLMULQDQ on the two independent 128-bit lanes                            */
/* ------------------------------------------------------------------------- */

static inline __m256i
_mm256_clmulepi64_epi128 (__m256i left, __m256i right, int control)
{
  __m256i result;
  for (int lane = 0; lane < 2; lane++)
    {
      int left_word = lane * 2 + ((control & 1) != 0);
      int right_word = lane * 2 + ((control & 16) != 0);
      unsigned long long left_value = 0;
      unsigned long long right_value = 0;
      unsigned long long low = 0;
      unsigned long long high = 0;
      for (int byte = 0; byte < 8; byte++)
        {
          left_value |=
            (unsigned long long) left.bytes[left_word * 8 + byte]
            << (byte * 8);
          right_value |=
            (unsigned long long) right.bytes[right_word * 8 + byte]
            << (byte * 8);
        }
      for (int bit = 0; bit < 64; bit++)
        if (((right_value >> bit) & 1) != 0)
          {
            low ^= left_value << bit;
            if (bit != 0)
              high ^= left_value >> (64 - bit);
          }
      for (int byte = 0; byte < 8; byte++)
        {
          result.bytes[lane * 16 + byte] =
            (unsigned char) (low >> (byte * 8));
          result.bytes[lane * 16 + 8 + byte] =
            (unsigned char) (high >> (byte * 8));
        }
    }
  return result;
}
#endif
/* end of x86intrin.h */
