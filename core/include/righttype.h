// C interface to the RightType core (core/src/lib.rs). Used from Swift as the
// bridging header; keep in step with the Rust side.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define RT_LAYOUT_NONE (-1)
#define RT_LAYOUT_ENGLISH 0
#define RT_LAYOUT_THAI 1

#define RT_NOTE_NONE 0
#define RT_NOTE_FIXED 1
#define RT_NOTE_FIXED_MANY 2
#define RT_NOTE_REVERTED 3
#define RT_NOTE_NOTHING 4
#define RT_NOTE_SNIPPET 5
#define RT_NOTE_TYPO 6

#define RT_MODE_OFF 0
#define RT_MODE_MANUAL 1
#define RT_MODE_SEMI_AUTO 2
#define RT_MODE_AUTO 3
#define RT_MODE_SUGGEST 4
#define RT_MODE_CODE 5

#define RT_SNIP_MAC_UNSUPPORTED 6

#define RT_TRANSFORM_REPAIR 0
#define RT_TRANSFORM_NORMALIZE 1
#define RT_TRANSFORM_SPACING 2
#define RT_TRANSFORM_ERA 3
#define RT_TRANSFORM_NUMBER_WORDS 4
#define RT_TRANSFORM_BAHT_WORDS 5
#define RT_TRANSFORM_DIGITS 6
#define RT_TRANSFORM_UPPER 7
#define RT_TRANSFORM_LOWER 8
#define RT_TRANSFORM_TITLE 9
#define RT_TRANSFORM_SWAP_CASE 10
#define RT_TRANSFORM_FLIP 11

typedef struct RtEngine RtEngine;

typedef struct {
    uint32_t backspaces;
    char *insert;
    uint32_t boundary;
    int32_t layout;
    int32_t note;
    uint32_t words;
    bool swallow;
    char *hint;
    char *steps;
} RtAction;

RtEngine *rt_engine_new(void);
void rt_engine_free(RtEngine *engine);
bool rt_key(RtEngine *engine, uint32_t key, int32_t layout, int32_t mode, RtAction *out);
bool rt_backspace(RtEngine *engine, int32_t mode, RtAction *out);
void rt_reset(RtEngine *engine, bool also_recent);
bool rt_layout_changed(RtEngine *engine, RtAction *out);
bool rt_boundary(RtEngine *engine, uint32_t boundary, int32_t layout, int32_t mode, RtAction *out);
bool rt_tab(RtEngine *engine, RtAction *out);
bool rt_code_wants_line(const RtEngine *engine, int32_t layout);
void rt_code_line(RtEngine *engine, const char *before);
void rt_flip(RtEngine *engine, RtAction *out);
void rt_action_clear(RtAction *action);
char *rt_repair(const char *text);
uint32_t rt_kedmanee(uint32_t key);
void rt_string_free(char *s);

void rt_snippets_clear(RtEngine *engine);
int32_t rt_snippet_add(RtEngine *engine, const char *trigger, const char *text, int32_t scope);
int32_t rt_snippet_check(const char *trigger, const char *text, int32_t scope);
char *rt_snippet_preview(const char *text);
void rt_set_options(RtEngine *engine, bool spelling, bool addresses);

void rt_learn_open(const char *path);
void rt_learn_set(bool reversed, bool typed);
char *rt_learn_list(void);
uint32_t rt_learn_count(void);
uint32_t rt_learn_replace(const char *lines, uint32_t *kept);
char *rt_learn_add(const char *word);
char *rt_learn_candidate(const char *selection);
void rt_learn_clear(void);
char *rt_learn_reversed(void);
void rt_learn_keep(const char *word);

char *rt_transform(int32_t kind, const char *text);
