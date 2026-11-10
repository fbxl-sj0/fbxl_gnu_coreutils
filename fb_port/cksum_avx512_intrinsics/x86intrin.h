/*
    Project: GNU Coreutils FreeBASIC port
    File: x86intrin.h

    Purpose:

        Provide a C2FB-compatible representation of the AVX-512 operations
        used by src/cksum_avx512.c and src/wc_avx512.c.

    Responsibilities:

        - Describe each 512-bit value as 64 byte-addressable bytes.
        - Preserve constructors, loads, stores, byte comparisons and masks,
          lane-local shuffles, XOR, and carryless multiplication in C helpers
          for C2FB.
        - Replace the host GCC intrinsic header only in this source context.

    This file intentionally does NOT contain:

        - CPU feature detection or dispatch.
        - The checksum and line-counting algorithms in the source files.
        - The native C reference used by runtime comparisons.
*/
#ifndef COREUTILS_C2FB_AVX512_INTRINSICS_H
#define COREUTILS_C2FB_AVX512_INTRINSICS_H 1

/* This header is selected before the host x86intrin.h in C2FB's context. */
#ifndef _X86INTRIN_H_INCLUDED
#define _X86INTRIN_H_INCLUDED 1
#endif

typedef struct avx512_vector512
{
  unsigned char bytes[64];
} __m512i;
typedef __m512i __m512i_u;

/* ------------------------------------------------------------------------- */
/* Constructors                                                              */
/* ------------------------------------------------------------------------- */

static inline __m512i
_mm512_set_epi64 (long long e7, long long e6, long long e5, long long e4,
                  long long e3, long long e2, long long e1, long long e0)
{
  __m512i result;
  unsigned long long words[8];
  words[0] = (unsigned long long) e0;
  words[1] = (unsigned long long) e1;
  words[2] = (unsigned long long) e2;
  words[3] = (unsigned long long) e3;
  words[4] = (unsigned long long) e4;
  words[5] = (unsigned long long) e5;
  words[6] = (unsigned long long) e6;
  words[7] = (unsigned long long) e7;
  for (int lane = 0; lane < 8; lane++)
    for (int byte = 0; byte < 8; byte++)
      result.bytes[lane * 8 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

static inline __m512i
_mm512_set_epi8 (
    char e63, char e62, char e61, char e60, char e59, char e58, char e57,
    char e56, char e55, char e54, char e53, char e52, char e51, char e50,
    char e49, char e48, char e47, char e46, char e45, char e44, char e43,
    char e42, char e41, char e40, char e39, char e38, char e37, char e36,
    char e35, char e34, char e33, char e32, char e31, char e30, char e29,
    char e28, char e27, char e26, char e25, char e24, char e23, char e22,
    char e21, char e20, char e19, char e18, char e17, char e16, char e15,
    char e14, char e13, char e12, char e11, char e10, char e9, char e8,
    char e7, char e6, char e5, char e4, char e3, char e2, char e1, char e0)
{
  __m512i result;
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
  result.bytes[32] = (unsigned char) e32;
  result.bytes[33] = (unsigned char) e33;
  result.bytes[34] = (unsigned char) e34;
  result.bytes[35] = (unsigned char) e35;
  result.bytes[36] = (unsigned char) e36;
  result.bytes[37] = (unsigned char) e37;
  result.bytes[38] = (unsigned char) e38;
  result.bytes[39] = (unsigned char) e39;
  result.bytes[40] = (unsigned char) e40;
  result.bytes[41] = (unsigned char) e41;
  result.bytes[42] = (unsigned char) e42;
  result.bytes[43] = (unsigned char) e43;
  result.bytes[44] = (unsigned char) e44;
  result.bytes[45] = (unsigned char) e45;
  result.bytes[46] = (unsigned char) e46;
  result.bytes[47] = (unsigned char) e47;
  result.bytes[48] = (unsigned char) e48;
  result.bytes[49] = (unsigned char) e49;
  result.bytes[50] = (unsigned char) e50;
  result.bytes[51] = (unsigned char) e51;
  result.bytes[52] = (unsigned char) e52;
  result.bytes[53] = (unsigned char) e53;
  result.bytes[54] = (unsigned char) e54;
  result.bytes[55] = (unsigned char) e55;
  result.bytes[56] = (unsigned char) e56;
  result.bytes[57] = (unsigned char) e57;
  result.bytes[58] = (unsigned char) e58;
  result.bytes[59] = (unsigned char) e59;
  result.bytes[60] = (unsigned char) e60;
  result.bytes[61] = (unsigned char) e61;
  result.bytes[62] = (unsigned char) e62;
  result.bytes[63] = (unsigned char) e63;
  return result;
}

static inline __m512i
_mm512_set_epi32 (
    int e15, int e14, int e13, int e12, int e11, int e10, int e9, int e8,
    int e7, int e6, int e5, int e4, int e3, int e2, int e1, int e0)
{
  __m512i result;
  unsigned int words[16];
  words[0] = (unsigned int) e0;
  words[1] = (unsigned int) e1;
  words[2] = (unsigned int) e2;
  words[3] = (unsigned int) e3;
  words[4] = (unsigned int) e4;
  words[5] = (unsigned int) e5;
  words[6] = (unsigned int) e6;
  words[7] = (unsigned int) e7;
  words[8] = (unsigned int) e8;
  words[9] = (unsigned int) e9;
  words[10] = (unsigned int) e10;
  words[11] = (unsigned int) e11;
  words[12] = (unsigned int) e12;
  words[13] = (unsigned int) e13;
  words[14] = (unsigned int) e14;
  words[15] = (unsigned int) e15;
  for (int lane = 0; lane < 16; lane++)
    for (int byte = 0; byte < 4; byte++)
      result.bytes[lane * 4 + byte] =
        (unsigned char) (words[lane] >> (byte * 8));
  return result;
}

static inline __m512i
_mm512_set1_epi8 (char value)
{
  __m512i result;
  for (int byte = 0; byte < 64; byte++)
    result.bytes[byte] = (unsigned char) value;
  return result;
}

/* ------------------------------------------------------------------------- */
/* Loads, stores, lane-local shuffle, and XOR                                */
/* ------------------------------------------------------------------------- */

static inline __m512i
_mm512_loadu_si512 (const __m512i_u *source)
{
  return *source;
}

static inline __m512i
_mm512_load_si512 (const __m512i_u *source)
{
  return *source;
}

static inline void
_mm512_storeu_si512 (__m512i_u *destination, __m512i value)
{
  *destination = value;
}

static inline __m512i
_mm512_xor_si512 (__m512i left, __m512i right)
{
  __m512i result;
  for (int byte = 0; byte < 64; byte++)
    result.bytes[byte] = left.bytes[byte] ^ right.bytes[byte];
  return result;
}

static inline unsigned long long
_mm512_cmpeq_epi8_mask (__m512i left, __m512i right)
{
  unsigned long long mask = 0;
  for (int byte = 0; byte < 64; byte++)
    if (left.bytes[byte] == right.bytes[byte])
      mask |= 1ULL << byte;
  return mask;
}

static inline __m512i
_mm512_shuffle_epi8 (__m512i value, __m512i indices)
{
  __m512i result;
  for (int byte = 0; byte < 64; byte++)
    {
      unsigned char control = indices.bytes[byte];
      if ((control & 0x80) != 0)
        result.bytes[byte] = 0;
      else
        /* VPSHUFB selects within each independent 16-byte lane. */
        result.bytes[byte] =
          value.bytes[(byte & 48) + (control & 0x0f)];
    }
  return result;
}

/* ------------------------------------------------------------------------- */
/* PCLMULQDQ on four independent 128-bit lanes                               */
/* ------------------------------------------------------------------------- */

static inline __m512i
_mm512_clmulepi64_epi128 (__m512i left, __m512i right, int control)
{
  __m512i result;
  for (int lane = 0; lane < 4; lane++)
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
