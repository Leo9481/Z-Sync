// The C interface of rust/zb-adblock (Brave's adblock-rust), built by CI as
// a static library for iOS. Used as the app's bridging header.
#ifndef ZBAdblock_h
#define ZBAdblock_h

typedef struct ZbEngine ZbEngine;

/// An engine with the cosmetic rules of uBlock Origin's own lists (trusted,
/// may be NULL) and of the other lists.
ZbEngine * _Nullable zb_engine_new(const char * _Nullable trusted_text, const char * _Nonnull list_text);
void zb_engine_free(ZbEngine * _Nullable engine);

/// Loads scriptlet resources (a JSON array); returns how many, or -1.
int zb_engine_use_resources(ZbEngine * _Nonnull engine, const char * _Nonnull resources_json);

/// The page's hiding resources as JSON; free with zb_string_free.
char * _Nullable zb_engine_url_cosmetic(const ZbEngine * _Nonnull engine, const char * _Nonnull url);

/// Generic selectors for {"classes", "ids", "exceptions"} as a JSON array; free with zb_string_free.
char * _Nullable zb_engine_hidden_selectors(const ZbEngine * _Nonnull engine, const char * _Nonnull request);

void zb_string_free(char * _Nullable text);

#include "../VPN/ZBWireGuard.h"

#endif
