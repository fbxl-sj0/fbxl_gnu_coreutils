/*
    Project: SQLite FreeBASIC port tools
    File: layouts.c
    Purpose: Check array and pointer members against a matching BASIC layout.
    Responsibilities: Exercise indexed, nested, grouped, and decayed arrays.
    This file intentionally does NOT contain: SQLite engine structure layouts.
*/

typedef struct Nested Nested;
typedef struct sqlite3 sqlite3;
typedef struct Opaque Opaque;
struct Nested { int values[2]; };
struct sqlite3 {
  int items[4];
  int *pointerItems;
  Nested nested[2];
  Nested *child;
  struct { Nested *value; } u;
  int (*callback)(sqlite3 *, int);
  int (*nativeCallback)(sqlite3 *, int);
  Opaque *opaque;
};

int c2fbFieldArray(sqlite3 *p, int i){
  return p->items[i] + p->nested[i % 2].values[1];
}

int c2fbFieldPointer(sqlite3 *p, int i){
  return p->pointerItems[i];
}

int c2fbFieldGrouped(sqlite3 *p, int i){
  return (p->items)[i];
}

int c2fbFieldDecay(sqlite3 *p, int i){
  int *a = p->items;
  return a[i];
}

void c2fbFieldWrite(sqlite3 *p, int i, int value){
  p->items[i] = value;
}

int c2fbOpaqueChild(sqlite3 *p, int i){
  return p->child->values[i];
}

int c2fbOpaqueNestedChild(sqlite3 *p, int i){
  return p->u.value->values[i];
}

int c2fbOpaqueChildWrite(sqlite3 *p, int i){
  p->child->values[i] = 53;
  return p->child->values[i];
}

int c2fbOpaqueChildAssign(sqlite3 *p, int i){
  p->u.value = p->child;
  return p->u.value->values[i];
}

int c2fbOpaqueChildIncrement(sqlite3 *p, int i){
  p->child++;
  return p->child->values[i];
}

int c2fbOpaqueChildAddress(sqlite3 *p, int i){
  Nested **address = &p->u.value;
  *address = p->child;
  return p->u.value->values[i];
}

int c2fbFieldCallback(sqlite3 *p, int i){
  return p->callback(p, i);
}

static int c2fbFieldCallbackHelper(sqlite3 *p, int i){
  return p->items[i] + 5;
}

int c2fbFieldCallbackAssign(sqlite3 *p, int i){
  p->callback = c2fbFieldCallbackHelper;
  return p->callback(p, i);
}

int c2fbFieldCallbackStatement(sqlite3 *p, int i){
  p->callback(p, i);
  return p->items[i];
}

int c2fbFieldArrayPostfix(sqlite3 *p, int i){
  int j = i;
  int value = p->items[j++]++;
  return value + j * 100;
}

int c2fbFieldArrayAssignment(sqlite3 *p, int i){
  return p->items[i] += 3;
}

int c2fbOpaqueChildPostfix(sqlite3 *p, int i){
  Nested *child = p->child++;
  return child->values[i] + p->child->values[i];
}

static sqlite3 *c2fbFieldCallHelper(sqlite3 *p){ return p; }

int c2fbFieldCallIncrement(sqlite3 *p, int i){
  return c2fbFieldCallHelper(p)->items[i]++;
}

int c2fbFieldRecordSwap(sqlite3 *p, int i){
  Nested temporary;
  temporary = p->nested[0];
  p->nested[0] = p->nested[1];
  p->nested[1] = temporary;
  return p->nested[i % 2].values[0];
}

int c2fbFieldNativeCallbackAssign(sqlite3 *p, int i){
  p->nativeCallback = c2fbFieldCallbackHelper;
  return p->nativeCallback(p, i);
}

int c2fbFieldOpaqueWrite(sqlite3 *p, int i){
  p->opaque = 0;
  return (p->opaque == 0) + sizeof(p->opaque) + i;
}

int c2fbFieldArraySize(sqlite3 *p, int i){
  return sizeof(p->items) + sizeof(p->nested[i++ % 2].values) + i;
}

int c2fbOpaqueChildDirectPostfix(sqlite3 *p, int i){
  return p->child++->values[i]++;
}

/* end of layouts.c */
