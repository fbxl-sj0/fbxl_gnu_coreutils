/*
    Project: GNU Coreutils FreeBASIC port
    File: x86intrin.h

    Purpose:

        Provide a C2FB-compatible representation of the 128-bit operations
        used by src/cksum_pclmul.c and lib/crc-x86_64-pclmul.c.

    Responsibilities:

        - Describe each 128-bit value as 16 byte-addressable bytes.
        - Preserve the constructors, loads, stores, shuffle, bitwise
          operations, byte shifts, and carryless multiply used by both CRC
          routines.
        - Replace the host GCC intrinsic header only in this source context.

    This file intentionally does NOT contain:

        - CPU feature detection or dispatch.
        - The checksum and CRC algorithms from the source files.
        - The native C reference used by runtime comparisons.
*/
#ifndef COREUTILS_C2FB_PCLMUL_INTRINSICS_H
#define COREUTILS_C2FB_PCLMUL_INTRINSICS_H 1

/* This header is selected before the host x86intrin.h in C2FB's context. */
#ifndef _X86INTRIN_H_INCLUDED
#define _X86INTRIN_H_INCLUDED 1
#endif

typedef struct pclmul_vector128
{
  unsigned char bytes[16];
} __m128i;
typedef __m128i __m128i_u;

/* ------------------------------------------------------------------------- */
/* Constructors                                                              */
/* ------------------------------------------------------------------------- */

static inline __m128i
_mm_set_epi64x (long long e1, long long e0)
{
  __m128i result;
  unsigned long long words[2];
  words[0] = (unsigned long long) e0;
  words[1] = (unsigned long long) e1;
  for (int lane = 0; lane < 2; lane++)
    for (int byte = 0; byte < 8; byte++)
      result.bytes[lane * 8 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

static inline __m128i
_mm_set_epi8 (char e15, char e14, char e13, char e12,
              char e11, char e10, char e9, char e8,
              char e7, char e6, char e5, char e4,
              char e3, char e2, char e1, char e0)
{
  __m128i result;
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
  return result;
}

static inline __m128i
_mm_set_epi32 (int e3, int e2, int e1, int e0)
{
  __m128i result;
  unsigned int words[4];
  words[0] = (unsigned int) e0;
  words[1] = (unsigned int) e1;
  words[2] = (unsigned int) e2;
  words[3] = (unsigned int) e3;
  for (int lane = 0; lane < 4; lane++)
    for (int byte = 0; byte < 4; byte++)
      result.bytes[lane * 4 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

/* ------------------------------------------------------------------------- */
/* Loads, stores, shuffle, and XOR                                           */
/* ------------------------------------------------------------------------- */

static inline __m128i
_mm_loadu_si128 (const __m128i_u *source)
{
  return *source;
}

static inline void
_mm_storeu_si128 (__m128i_u *destination, __m128i value)
{
  *destination = value;
}

static inline __m128i
_mm_xor_si128 (__m128i left, __m128i right)
{
  __m128i result;
  for (int byte = 0; byte < 16; byte++)
    result.bytes[byte] = left.bytes[byte] ^ right.bytes[byte];
  return result;
}

static inline __m128i
_mm_shuffle_epi8 (__m128i value, __m128i indices)
{
  __m128i result;
  for (int byte = 0; byte < 16; byte++)
    {
      unsigned char control = indices.bytes[byte];
      if ((control & 0x80) != 0)
        result.bytes[byte] = 0;
      else
        result.bytes[byte] = value.bytes[control & 0x0f];
    }
  return result;
}

/* ------------------------------------------------------------------------- */
/* PCLMULQDQ                                                                 */
/* ------------------------------------------------------------------------- */

static inline __m128i
_mm_clmulepi64_si128 (__m128i left, __m128i right, int control)
{
  __m128i result;
  int left_word = (control & 1) != 0;
  int right_word = (control & 16) != 0;
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

        /* Keep the high-half shift in the range 1 through 63. */
        if (bit != 0)
          high ^= left_value >> (64 - bit);
      }

  for (int byte = 0; byte < 8; byte++)
    {
      result.bytes[byte] = (unsigned char) (low >> (byte * 8));
      result.bytes[8 + byte] = (unsigned char) (high >> (byte * 8));
    }
  return result;
}

/* ------------------------------------------------------------------------- */
/* Byte masks, shifts, and extraction                                        */
/* ------------------------------------------------------------------------- */

static inline __m128i
_mm_and_si128 (__m128i left, __m128i right)
{
  __m128i result;
  for (int byte = 0; byte < 16; byte++)
    result.bytes[byte] = left.bytes[byte] & right.bytes[byte];
  return result;
}

static inline __m128i
_mm_srli_si128 (__m128i value, int shift)
{
  __m128i result;
  for (int byte = 0; byte < 16; byte++)
    {
      if (shift >= 0 && shift < 16 && byte < 16 - shift)
        result.bytes[byte] = value.bytes[byte + shift];
      else
        result.bytes[byte] = 0;
    }
  return result;
}

static inline int
_mm_cvtsi128_si32 (__m128i value)
{
  unsigned int low_word = 0;
  for (int byte = 0; byte < 4; byte++)
    low_word |= (unsigned int) value.bytes[byte] << (byte * 8);
  return (int) low_word;
}
#endif
/* end of x86intrin.h */
