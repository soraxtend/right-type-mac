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

typedef struct RtEngine RtEngine;

typedef struct {
    uint32_t backspaces;
    char *insert;
    uint32_t boundary;
    int32_t layout;
    int32_t note;
    uint32_t words;
    bool swallow;
} RtAction;

RtEngine *rt_engine_new(void);
void rt_engine_free(RtEngine *engine);
bool rt_key(RtEngine *engine, uint32_t key, int32_t layout, bool live, RtAction *out);
bool rt_backspace(RtEngine *engine, bool live, RtAction *out);
void rt_reset(RtEngine *engine, bool also_recent);
bool rt_layout_changed(RtEngine *engine, RtAction *out);
bool rt_boundary(RtEngine *engine, uint32_t boundary, int32_t layout, bool autofix, RtAction *out);
void rt_flip(RtEngine *engine, RtAction *out);
void rt_action_clear(RtAction *action);
char *rt_repair(const char *text);
uint32_t rt_kedmanee(uint32_t key);
void rt_string_free(char *s);
