/*
    Project: SQLite FreeBASIC port tools

    File: expressions.c

    Purpose:

        Provide C behavior references for bulk expression conversion.

    Responsibilities:

        - Exercise C precedence, integer widths, casts, and character escapes.
        - Exercise boolean values in returns, assignments, and call arguments.
        - Check that conditional expressions evaluate only their selected arm.
        - Check ordered side effects in values, calls, and loop conditions.

    This file intentionally does NOT contain:

        - SQLite engine changes or implementations of unported dependencies.
*/

int sqlite3AbsInt32(int);
typedef signed char i8;
typedef unsigned short Counter16;
typedef unsigned int Counter32;
typedef Counter32 Counter;
typedef const Counter *CounterPointer;
typedef char *TextPointer;
typedef int (*UnaryCallback)(int);

int c2fbCallbackParameter(int (*callback)(int), int a){
  return callback(a) + 1;
}

int c2fbCallbackAlias(UnaryCallback callback, double a){
  return callback(a);
}

void c2fbCallbackVoid(void (*callback)(int *, int), int *p, int a){
  callback(p, a);
}

static int c2fbCallbackHelper(int a){ return a + 3; }

int c2fbCallbackDecay(int a){
  return c2fbCallbackParameter(c2fbCallbackHelper, a);
}

int c2fbCallbackAddress(int a){
  return c2fbCallbackParameter(&c2fbCallbackHelper, a);
}

int c2fbStaticLocal(int a){
  static int total = 0;
  if( a == 0x7fffffff ){
    total = 0;
    return total;
  }
  total += a;
  return total;
}

int c2fbStaticLocalAfterStatement(int a){
  a += 1;
  static int bias = 0;
  return bias + a;
}

int c2fbWideCharacter(void){
  return L'a';
}

int c2fbCallbackLocal(UnaryCallback callback, int a){
  UnaryCallback localCallback = callback;
  return localCallback(a);
}

int c2fbCallbackSize(UnaryCallback callback){
  return sizeof(callback);
}

int c2fbCallbackCast(void *callback, int a){
  return ((int (*)(int))callback)(a);
}

int c2fbCallbackNull(UnaryCallback callback){
  return callback == 0;
}

int c2fbCallbackSentinel(void (*callback)(void *)){
  return callback == ((void (*)(void *))-1);
}
int strcmp(const char *, const char *);
unsigned long strlen(const char *);
double floor(double);
void *memcpy(void *, const void *, unsigned long);

static int c2fbLocalAfter(int a);
int c2fbLocalCaller(int a){ return c2fbLocalAfter(a); }
static int c2fbLocalAfter(int a){ return a + 3; }

static int c2fbRecursiveHelper(int a){
  if( a <= 0 ) return 1;
  return a * c2fbRecursiveHelper(a - 1);
}
int c2fbRecursiveCaller(int a){ return c2fbRecursiveHelper(a); }

int c2fbRuntimeStrings(int a){
  if( a ) return strcmp("abc", "abd");
  return strlen("A\0B");
}
double c2fbRuntimeMath(double a){ return floor(a); }

int c2fbRuntimeMemory(void){
  int value = 0;
  const char *text = "123";
  memcpy(&value, text, 1);
  return value;
}

int c2fbMultipleDeclarations(int a){
  int x = a, y = x + 1, z;
  z = x + y;
  return z;
}

int c2fbMixedDeclarations(int a){
  int *p = &a, n = 2, *q = p;
  return *q + n;
}

int c2fbShadowScopes(int a){
  int x = a;
  {
    int x = 2;
    {
      int x = 3;
      a += x;
    }
    a += x;
  }
  return a + x;
}

int c2fbBranchScopes(int a){
  if( a ){
    int x = 3;
    a += x;
  }else{
    int x = 7;
    a += x;
  }
  return a;
}

int c2fbForExits(int a){
  int n = 0;
  for(int i = 0; i < a; i++){
    if( i == 2 ) continue;
    if( i == 6 ) break;
    n += i;
  }
  return n;
}

int c2fbWhileExits(int a){
  int n = 0;
  while( a > 0 ){
    a--;
    if( a == 2 ) continue;
    if( a == 6 ) break;
    n += a;
  }
  return n;
}

int c2fbDoExits(int a){
  int n = 0;
  do{
    a--;
    if( a == 2 ) continue;
    if( a == 6 ) break;
    n += a;
  }while( a > 0 );
  return n;
}

int c2fbForComma(int a){
  int i, j, n = 0;
  for(i = 0, j = a; i < a; (i++, j--)){
    if( i == 2 ) continue;
    n += i + j;
  }
  return n;
}

int c2fbForScopeReuse(int a){
  int n = 0;
  for(int i = 0; i < a; i++) n += i;
  for(int i = 0; i < a; i++) n += i;
  return n;
}

int c2fbSwitchInLoop(int a){
  int n = 0;
  for(int i = 0; i < a; i++){
    switch( i % 4 ){
      case 0: continue;
      case 1:
        if( i > 3 ) break;
        n += 10;
        break;
      case 2: n += 2; break;
      default: n += 3; break;
    }
    n++;
  }
  return n;
}

int c2fbGotoCleanup(int a){
  int n = 0;
  if( a < 0 ) goto cleanup;
  {
    int x = 3;
    n += x;
    if( a == 0 ) goto cleanup;
    n += a;
  }
cleanup:
  return n;
}

int c2fbGotoCases(int a){
  if( a ) goto done;
  goto DONE;
done:
  return 3;
DONE:
  return 7;
}

int c2fbInfiniteFor(int a){
  for(;;){
    if( a <= 0 ) return 3;
    a--;
  }
}

int c2fbLocalArray(int a){
  int items[4] = {a, 2};
  return items[0] + items[1] + items[2] + items[3];
}

int c2fbLocalArrayPointer(int a){
  int items[4] = {1, 2, 3, 4};
  int *p = items;
  p[2] = a;
  return items[2];
}

int c2fbLocalArraySize(void){
  unsigned char items[5];
  return sizeof(items) + sizeof(items[0]);
}

int c2fbLocalArrayLoop(int a){
  int n = 0;
  for(int i = 0; i < a; i++){
    int items[2] = {i};
    n += items[1];
    items[1] = 7;
    n += items[0];
  }
  return n;
}

int c2fbLocalArrayDeclarations(int a){
  int items[2] = {a, 3}, others[2] = {4, 5};
  return items[0] + others[0];
}

int c2fbLargeLocalArray(int value){
  unsigned char items[65536];
  items[0] = (unsigned char)value;
  items[65535] = (unsigned char)(value + 1);
  return items[0] + items[65535];
}

int c2fbLocalMatrix(int row, int column){
  int matrix[2][3];
  for(int r = 0; r < 2; r++){
    for(int c = 0; c < 3; c++) matrix[r][c] = r * 10 + c;
  }
  int *rowPointer = matrix[row];
  return (int)(sizeof(matrix) / sizeof(matrix[0])) * 100 +
         (int)(sizeof(matrix[0]) / sizeof(matrix[0][0])) * 10 +
         rowPointer[column];
}

int c2fbLocalMatrixInitNested(int row, int column){
  int matrix[2][3] = {{1, 2}, {3}};
  return matrix[0][0] * 100000 + matrix[0][1] * 10000 +
         matrix[0][2] * 1000 + matrix[1][0] * 100 +
         matrix[1][1] * 10 + matrix[1][2] + matrix[row][column];
}

int c2fbLocalMatrixInitFlat(int row, int column){
  int matrix[2][3] = {1, 2, 3, 4, 5, 6};
  return matrix[0][0] * 100000 + matrix[0][1] * 10000 +
         matrix[0][2] * 1000 + matrix[1][0] * 100 +
         matrix[1][1] * 10 + matrix[1][2] + matrix[row][column];
}

int c2fbLocalCubeInitNested(int row, int column, int depth){
  int cube[2][2][2] = {{{1}, {2}}, {{3}}};
  return cube[0][0][0] * 10000000 + cube[0][0][1] * 1000000 +
         cube[0][1][0] * 100000 + cube[0][1][1] * 10000 +
         cube[1][0][0] * 1000 + cube[1][0][1] * 100 +
         cube[1][1][0] * 10 + cube[1][1][1] +
         cube[row][column][depth];
}

int c2fbLocalCube(int row, int column, int depth){
  int cube[2][3][4];
  cube[row][column][depth] = row * 100 + column * 10 + depth;
  return (int)(sizeof(cube) / sizeof(cube[0])) * 1000 +
         (int)(sizeof(cube[0]) / sizeof(cube[0][0])) * 100 +
         (int)(sizeof(cube[0][0]) / sizeof(cube[0][0][0])) * 10 +
         cube[row][column][depth];
}

int c2fbVlaMatrix(int rows, int columns, int row, int column){
  int matrix[rows + 1][columns];
  for(int r = 0; r < rows + 1; r++){
    for(int c = 0; c < columns; c++) matrix[r][c] = r * 100 + c;
  }
  rows = -1;
  columns = -2;
  return (int)(sizeof(matrix) / sizeof(matrix[0])) * 10000 +
         (int)(sizeof(matrix[0]) / sizeof(matrix[0][0])) * 100 +
         matrix[row][column] + rows + columns;
}

int c2fbLargeLocalMatrix(int value){
  unsigned char matrix[2][32768];
  matrix[0][0] = (unsigned char)value;
  matrix[1][32767] = (unsigned char)(value + 1);
  return (int)(sizeof(matrix) / sizeof(matrix[0])) * 10 +
         (int)(sizeof(matrix[0]) / sizeof(matrix[0][0])) +
         matrix[0][0] + matrix[1][32767];
}

int c2fbLargeInitializedVector(void){
  int items[65536] = {1};
  return items[0] * 100 + items[1] * 10 + items[65534];
}

int c2fbLargeInitializedMatrix(void){
  int items[2][32768] = {1};
  return items[0][0] * 100 + items[0][1] * 10 +
         items[1][0] + items[1][32767];
}

int c2fbVlaSizeOnce(int count){
  int items[count];
  for(int i = 0; i < count; i++) items[i] = i + 1;
  int *alias = items;
  int original = count;
  count += 2;
  return (int)(sizeof(items) / sizeof(items[0])) * 100 + alias[original - 1] + count;
}

int c2fbVlaPostfixBound(int count){
  int items[count++];
  for(int i = 0; i < count - 1; i++) items[i] = i + 1;
  return (int)(sizeof(items) / sizeof(items[0])) * 100 + count + items[count - 2];
}

int c2fbVlaMatrixPostfixBound(int rows, int columns){
  int items[rows++][columns];
  return (int)(sizeof(items) / sizeof(items[0])) * 100 +
         (int)(sizeof(items[0]) / sizeof(items[0][0])) * 10 + rows;
}

int c2fbVlaMatrixIndependentSideEffects(int rows, int columns){
  int items[rows++][columns++];
  return rows * 1000 + columns * 100 +
         (int)(sizeof(items) / sizeof(items[0])) * 10 +
         (int)(sizeof(items[0]) / sizeof(items[0][0]));
}

int c2fbVlaLoop(int count){
  int total = 0;
  for(int current = 1; current <= count; current++){
    int items[current];
    for(int i = 0; i < current; i++) items[i] = current + i;
    total += (int)(sizeof(items) / sizeof(items[0])) + items[current - 1];
  }
  return total;
}

int c2fbTypedefCast(int a){
  Counter16 n = (Counter16)a;
  return n;
}

Counter c2fbTypedefArithmetic(Counter a, Counter b){
  return a + b;
}

Counter c2fbTypedefPointer(CounterPointer a, int i){
  return a[i];
}

int c2fbTypedefCharacterPointer(TextPointer a, int i){
  return a[i];
}

int c2fbKnownCallDivision(int a, int b){
  return sqlite3AbsInt32(a) / b;
}

int c2fbKnownCallArgument(double a){
  return sqlite3AbsInt32(a);
}

double c2fbFloatingLiterals(double a){
  return a * 3.141592653589793 + .5 - 5. + 1e-3 + 2E+2;
}

float c2fbSingleLiterals(float a){
  return a + .1f + 2.5F;
}

double c2fbNegativeZero(void){
  return -0.0;
}

const char *c2fbStringLiteral(void){
  return "A\0B" "\n\t\"\\\101\x42\377";
}

int c2fbStringIndex(int i){
  return "AbC9"[i];
}

const char *c2fbStringLocal(void){
  const char *p = "hello";
  return p;
}

int c2fbSizeofTypes(void){
  return sizeof(int) + sizeof(unsigned char) + sizeof(long long) + sizeof(double) + sizeof(void *);
}

int c2fbSizeofExpression(unsigned char a, int *p){
  return sizeof(a) + sizeof(a + a) + sizeof(*p) + sizeof(p);
}

int c2fbSizeofNoEvaluation(int a, int *p){
  return sizeof(++a) + sizeof(a++) + sizeof(*p++) + a;
}

int c2fbSizeofString(void){
  return sizeof("A\0B") + sizeof("" "x");
}

int c2fbSizeofCall(int a){
  return sizeof(sqlite3AbsInt32(a));
}

int c2fbVoidZero(int a){
  ((void)0);
  (void)(0);
  return a;
}

i8 c2fbSignedByte(i8 a){
  return a;
}

int c2fbSignedBytePointer(const i8 *a, int i){
  return a[i];
}

int c2fbPrecedence(int a, int b, int c){
  return (a & b == c) + (a | b ^ c) + (a << b + c);
}

int c2fbAssociativity(int a, int b, int c){
  return a - b - c + (a < b < c) + (a == b == c);
}

int c2fbBooleanArithmetic(int a, int b){
  return (a == b) + 2 * !a + ((a && b) << 3) + 16 * (a || b);
}

int c2fbBooleanAssignment(int a, int b){
  int input = a < b;
  input = (input || a) + (a == b);
  return input;
}

int c2fbBooleanArgument(int a, int b){
  return sqlite3AbsInt32((a < b) + 2 * (a == b));
}

int c2fbIntegerDivision(int a, int b, int c){
  return a / b * c + a % b;
}

double c2fbFloatingDivision(double a, int b){
  return a / b;
}

float c2fbSingleDivision(float a, int b){
  return a / b;
}

int c2fbTruncate(double a){
  return (int)a;
}

int c2fbImplicitReturn(double a){
  return a;
}

int c2fbImplicitInitializer(double a){
  int x = a;
  return x;
}

int c2fbImplicitAssignment(int a, double b){
  a = b;
  return a;
}

int c2fbImplicitCompound(int a, double b){
  a += b;
  return a;
}

int c2fbIntegerCast(int a){
  return (unsigned char)a + (short)a;
}

unsigned int c2fbUnsignedLiteral(unsigned int a){
  return (a & 0x80000000U) | (~0U ^ a);
}

unsigned int c2fbUnsignedArithmetic(unsigned int a, unsigned int b, unsigned int c){
  return (a + b) / c + (a * b) % c;
}

int c2fbUnsignedComparison(unsigned int a, unsigned int b){
  return a + b < a;
}

unsigned long long c2fbUnsignedWideLiteral(unsigned long long a){
  return a ^ 0xffffffffffffffffULL;
}

long long c2fbWideLiteral(int a){
  return (long long)2147483648LL + a;
}

int c2fbMixedSignedness(int a, unsigned int b){
  return (a < b) + 2 * (a == b);
}

unsigned int c2fbMixedDivisionUnsigned(int a, unsigned int b){
  return a / b;
}

long long c2fbMixedDivisionWide(long long a, unsigned int b){
  return a / b;
}

unsigned long long c2fbMixedDivisionUnsignedWide(long long a, unsigned long long b){
  return a / b;
}

int c2fbHighHexComparison(long long a){
  return a == 0x80000000;
}

long long c2fbWideMixed(long long a, unsigned int b){
  return a + b + (a < b);
}

int c2fbPromoteBytes(unsigned char a, unsigned char b){
  return a + b + (~a == -1);
}

int c2fbCharacters(int a){
  return a + '\n' + '\t' + '\r' + '\a' + '\b' + '\v' + '\f'
         + '\\' + '\'' + '\"' + '\?' + '\101' + '\x41' + '\0' + ';';
}

int c2fbQuotedCondition(int a){
  if( a == ')' ) return '(';
  return ';';
}

int c2fbCharacterSwitch(int a){
  switch( a ){
    case ':': return '?';
    case ')': return '(';
    default: return ';';
  }
}

int c2fbSwitchMixedDefault(int mode){
  int result = 0;
  switch( mode ){
    case 1:
    default: {
      int amount = 7;
      int index;
      for( index = 0; index < 2; index++ )
        result += amount + index;
      break;
    }
    case 2:
      result += 2;
      break;
  }
  return result;
}

int c2fbSwitchFallthroughReturns(int value){
  switch( value ){
    case 0:
      value += 2;
    case 1:
      return value + 10;
    case 2:
      value++;
    default:
      return value - 3;
  }
}

int c2fbNestedConditional(int a, int b, int c){
  return a ? (b ? c : 4) : (b ? 5 : 6);
}

int c2fbConditionalAssignment(int a, int b){
  int output = a ? 1 : b ? 2 : 3;
  return output;
}

int c2fbConditionalEvaluation(int a, int b, int c){
  return a ? b / c : 7;
}

int c2fbLogicalEvaluation(int a, int b){
  return (a && b / a) + (a || b / (a + 1));
}

int c2fbChainedLogicalOrSideEffect(int a, int b){
  int calls = 0;
  int result = a || b || ++calls;
  return calls * 3 + result;
}

int c2fbPointerNegation(const int *a, int i){
  return !a[i] + !*a;
}

int c2fbPointerCast(void *a, int i){
  return ((int *)a)[i];
}

int c2fbCharacterPointer(const char *a, int i){
  return a[i] + *a;
}

int c2fbCharacterArgument(const char *a, int i){
  return sqlite3AbsInt32(a[i]);
}

void c2fbCharacterWrite(char *a, int i){
  a[i] = 'A';
}

int c2fbCaseSensitiveLocals(int a){
  int x = a;
  int X = x + 1;
  return X - x;
}

int c2fbComparisonInitializer(int a, int b){
  int x = a == b;
  return x;
}

int c2fbQuotedFor(void){
  int n = 0;
  int i;
  for(i = ';'; i < '='; i++) n++;
  return n;
}

int c2fbLoop(int a){
  int input = 0;
  int i;
  for(i = 0; i < a; i++) input += i == 2;
  return input;
}

int c2fbCompoundDivision(int a, int b){
  a /= b;
  return a;
}

unsigned int c2fbCompoundShift(unsigned int a, int b){
  a >>= b;
  a <<= 1;
  return a;
}

int c2fbPostfixValue(int a){ return a++; }
int c2fbPrefixValue(int a){ return ++a; }
int c2fbDecrementValues(int a){ int b = a--; return b + --a; }
int c2fbIncrementInitializer(int a){ int b = a++; return b * 3 + a; }
int c2fbAssignmentValue(int a){ return a = 2; }
int c2fbAssignmentChain(int a){ int b = 0; int c = 0; b = c = a + 3; return b + c; }
int c2fbCompoundValue(int a){ int b = (a *= 3); return b + a; }
int c2fbCompoundFloatValue(int a, double b){ int c = (a += b); return c + a; }
unsigned char c2fbNarrowAssignment(int a){ unsigned char b; return b = a; }
unsigned int c2fbUnsignedIncrement(unsigned int a){ return ++a; }
unsigned int c2fbUnsignedPostfix(unsigned int a){ unsigned int b = a++; return b ^ a; }
int c2fbCommaValue(int a){ return (a = 3, a += 2, a); }
int c2fbCommaPrecedence(int a){ int b = 0; return (b = a + 1, b *= 2, b + 3); }
int c2fbCommaCall(int a){ return (sqlite3AbsInt32(a), a++); }
int c2fbLazyAndEffect(int a){ int b = 0; int c = a && ++b; return b * 3 + c; }
int c2fbLazyOrEffect(int a){ int b = 0; int c = a || ++b; return b * 3 + c; }
int c2fbLazyNestedEffect(int a){ int b = 0; int c = a && (b = 2, b++ || ++b); return b * 3 + c; }
int c2fbConditionalEffect(int a){ int b = 1; int c = a ? b++ : (b = 7); return b * 3 + c; }
int c2fbConditionalComma(int a){ int b = 0; return a ? b = 2, b + 1 : b + 4; }
int c2fbConditionalPrecedence(int a){ int b = 0; return (b = a ? 5 : 9, b); }
int c2fbDiscardedEffects(int a){ (void)a++; (void)(a += 2); return a; }
int c2fbIfEffect(int a){ if( a++ > 0 ) a += 2; return a; }
int c2fbWhileEffect(int a){
  int total = 0;
  while( a-- > 0 ){
    if( a % 2 ) continue;
    total += a;
    if( a == 2 ) break;
  }
  return total * 100 + a;
}
int c2fbForEffect(int a){
  int total = 0;
  for( int i = 0; i++ < a; total += 1 ){
    if( i % 2 ) continue;
    total += i;
    if( i == 8 ) break;
  }
  return total;
}
int c2fbDoEffect(int a){
  int total = 0;
  do {
    total += 1;
    if( total % 2 ) continue;
    total += 2;
  } while( a-- > 0 );
  return total * 100 + a;
}
int c2fbSwitchEffect(int a){
  switch( a++ ){
    case 0: return ++a;
    case 1: return a++;
    default: return a;
  }
}
int c2fbIndexedIncrement(int a){
  int items[3] = {2, 4, 8};
  int i = 0;
  int b = items[i++]++;
  items[i++] += a++;
  return b + i * 10 + items[0] * 100 + items[1] * 1000;
}
int c2fbPointerIncrementValue(int a){
  int items[3] = {2, 4, 8};
  int *p = items;
  int b = *p++;
  *p++ += a;
  return b + *p * 10 + items[1] * 100;
}
int c2fbArrayInitializerEffect(int a){ int b[3] = {a++, a++, ++a}; return b[0] + b[1] * 10 + b[2] * 100; }
int c2fbSizeofEffects(int a){ return sizeof(a++) + sizeof(a = 2) + sizeof((a++, a)) + a; }
static int c2fbSequenceArgumentHelper(int a, int b){ return a * 3 + b; }
int c2fbSequencedArgument(int a){ return c2fbSequenceArgumentHelper((a += 2, a++), 5); }
static int c2fbSequenceCallHelper(int *p){ return ++*p; }
int c2fbSequencedCalls(int a){ return (c2fbSequenceCallHelper(&a), c2fbSequenceCallHelper(&a), a); }
int c2fbConditionalCalls(int a){ int b = 0; int c = a ? c2fbSequenceCallHelper(&b) : (b = 4); return c + b; }
int c2fbPointerArithmeticEffect(int a){
  int items[4] = {1, 3, 5, 7};
  int *p = items;
  int i = 0;
  int b = *(p + i++);
  return b + *(++i + p) + (p + 3 - p) * 10 + a;
}
int c2fbCharacterIncrement(void){ const char *p = "abc"; return *++p; }
int c2fbLazyPointerEffect(int a){ int b = 5; int *p = 0; if( a ) p = &b; return p && ++*p; }
int c2fbEmptyForEffect(int a){ int total = 0; for( ; a-- > 0; ) total++; return total * 100 + a; }
static void c2fbSequenceVoidHelper(int *p){ *p += 3; }
int c2fbVoidCommaEffect(int a){ return (c2fbSequenceVoidHelper(&a), a); }
int c2fbVoidConditionalEffect(int a){
  int b = 0;
  a ? (void)(b = 5) : (void)(b = 9);
  return b;
}
int c2fbCommaArraySize(void){ int values[3]; return sizeof((0, values)); }
int c2fbVoidCallConditionalEffect(int a){ int b = 0; a ? c2fbSequenceVoidHelper(&b) : c2fbSequenceVoidHelper(&a); return a + b; }
int c2fbPointerConditionalEffect(int a){ int values[2] = {3, 7}; int *p = values; int *q = a ? p++ : 0; return q ? *q + *p : 0; }
int c2fbNarrowPrefix(unsigned char a){ return ++a; }
int c2fbNarrowPostfix(unsigned char a){ int b = a++; return b * 10 + a; }
double c2fbFloatIncrementValue(double a){ double b = a++; return b - a; }
int c2fbPointerVoidConditionalEffect(int a){
  int values[2] = {3, 7};
  int *p = values;
  int *q = a ? p++ : (void *)0;
  return q ? *q + *p : 0;
}
int c2fbCallbackPointerElement(int *(*callback)(void), int a){
  callback()[0] += a;
  return callback()[0];
}

/* end of expressions.c */
