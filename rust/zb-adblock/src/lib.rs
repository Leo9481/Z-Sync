//! Z-Browser's C interface to Brave's adblock-rust, used for cosmetic
//! filtering only: the hiding rules a page needs (`##` rules for its site,
//! and generic rules for the classes and ids it uses). Network blocking is
//! done by WebKit content rules, so network rules are not loaded here.
//!
//! Strings cross the boundary as UTF-8 C strings; every string returned must
//! be released with `zb_string_free`, the engine with `zb_engine_free`.

use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;

pub struct ZbEngine(Engine);

fn read(text: *const c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned())
}

fn give(text: String) -> *mut c_char {
    // A NUL inside would cut the string short; there should be none in JSON.
    CString::new(text.replace('\0', "")).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// An engine with the cosmetic rules of two sets of filter lists (each joined
/// by newlines): `trusted_text` (uBlock Origin's own lists, which uBO trusts,
/// so their rules may use its trusted scriptlets) and `list_text` (the rest).
/// Null if `list_text` is null; `trusted_text` may be null.
#[no_mangle]
pub extern "C" fn zb_engine_new(trusted_text: *const c_char, list_text: *const c_char) -> *mut ZbEngine {
    let Some(text) = read(list_text) else { return ptr::null_mut() };
    let mut set = FilterSet::new(false);
    if let Some(trusted) = read(trusted_text) {
        // Bit 0: uBO's trusted resources (built with permission 1).
        let permissions: PermissionMask = serde_json::from_str("1").unwrap_or_default();
        set.add_filter_list(
            trusted,
            ParseOptions { rule_types: RuleTypes::CosmeticOnly, permissions, ..ParseOptions::default() },
        );
    }
    set.add_filter_list(
        text,
        ParseOptions { rule_types: RuleTypes::CosmeticOnly, ..ParseOptions::default() },
    );
    Box::into_raw(Box::new(ZbEngine(Engine::new_with_filter_set(set))))
}

/// Gives the engine its scriptlet resources: a JSON array of adblock-rust
/// `Resource`s (uBlock Origin's scriptlets, built by CI). Returns how many
/// were loaded, or -1 if the JSON couldn't be read.
#[no_mangle]
pub extern "C" fn zb_engine_use_resources(engine: *mut ZbEngine, resources_json: *const c_char) -> i32 {
    if engine.is_null() {
        return -1;
    }
    let Some(json) = read(resources_json) else { return -1 };
    let Ok(resources) = serde_json::from_str::<Vec<Resource>>(&json) else { return -1 };
    let count = resources.len() as i32;
    let engine = unsafe { &mut *engine };
    engine.0.use_resources(resources);
    count
}

#[no_mangle]
pub extern "C" fn zb_engine_free(engine: *mut ZbEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// The page's own resources as JSON: `hide_selectors`, `procedural_actions`,
/// `exceptions`, `injected_script`, `generichide`.
#[no_mangle]
pub extern "C" fn zb_engine_url_cosmetic(engine: *const ZbEngine, url: *const c_char) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    let Some(url) = read(url) else { return ptr::null_mut() };
    let engine = unsafe { &*engine };
    let resources = engine.0.url_cosmetic_resources(&url);
    give(serde_json::to_string(&resources).unwrap_or_default())
}

/// Generic hiding selectors for the classes and ids a page uses. Takes
/// `{"classes": [...], "ids": [...], "exceptions": [...]}`, gives a JSON array.
#[no_mangle]
pub extern "C" fn zb_engine_hidden_selectors(engine: *const ZbEngine, request: *const c_char) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    let Some(request) = read(request) else { return ptr::null_mut() };
    let value: serde_json::Value = serde_json::from_str(&request).unwrap_or(serde_json::Value::Null);
    let list = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(|items| items.as_array())
            .map(|items| items.iter().filter_map(|item| item.as_str().map(String::from)).collect())
            .unwrap_or_default()
    };
    let classes = list("classes");
    let ids = list("ids");
    let exceptions: HashSet<String> = list("exceptions").into_iter().collect();
    let engine = unsafe { &*engine };
    let selectors = engine.0.hidden_class_id_selectors(classes.iter(), ids.iter(), &exceptions);
    give(serde_json::to_string(&selectors).unwrap_or_else(|_| "[]".into()))
}

#[no_mangle]
pub extern "C" fn zb_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}
