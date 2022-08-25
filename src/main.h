#ifndef MAIN_H_
#define MAIN_H_

#include "lv2/atom/atom.h"
#include "lv2/atom/util.h"

LV2_Atom_Event *atom_sequence_begin(const LV2_Atom_Sequence_Body *body);
LV2_Atom_Event *atom_sequence_end(const LV2_Atom_Sequence_Body *body,
                                  uint32_t size);
bool atom_sequence_is_end(const LV2_Atom_Sequence_Body *body, uint32_t size,
                          const LV2_Atom_Event *i);
LV2_Atom_Event *atom_sequence_next(const LV2_Atom_Event *i);

#endif // MAIN_H_
