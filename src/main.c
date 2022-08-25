#include "main.h"

LV2_Atom_Event *atom_sequence_begin(const LV2_Atom_Sequence_Body *body) {
  return lv2_atom_sequence_begin(body);
}

/** Get an iterator pointing to the end of a Sequence body. */
LV2_Atom_Event *atom_sequence_end(const LV2_Atom_Sequence_Body *body,
                                  uint32_t size) {
  return lv2_atom_sequence_end(body, size);
}

/** Return true iff `i` has reached the end of `body`. */
bool atom_sequence_is_end(const LV2_Atom_Sequence_Body *body, uint32_t size,
                          const LV2_Atom_Event *i) {
  return lv2_atom_sequence_is_end(body, size, i);
}

/** Return an iterator to the element following `i`. */
LV2_Atom_Event *atom_sequence_next(const LV2_Atom_Event *i) {
  return lv2_atom_sequence_next(i);
}
