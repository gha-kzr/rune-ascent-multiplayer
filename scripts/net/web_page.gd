class_name WebPage
extends RefCounted
## What the browser page knows, when the game runs in one: its address (and the part after #, where an
## invite link keeps its code), and the clipboard. Elsewhere these answer with harmless defaults.

const DEFAULT_URL := "https://gha-kzr.github.io/rune-ascent-multiplayer/"


static func is_web() -> bool:
	return OS.has_feature("web")


## The page's address, without a fragment.
static func url() -> String:
	if is_web():
		var href: Variant = JavaScriptBridge.eval("window.location.href.split('#')[0]", true)
		if href is String and not (href as String).is_empty():
			return href
	return DEFAULT_URL


## The text after the # of the page's address ("" outside a browser).
static func fragment() -> String:
	if is_web():
		var hash_text: Variant = JavaScriptBridge.eval("window.location.hash", true)
		if hash_text is String:
			return (hash_text as String).trim_prefix("#")
	return ""


## Removes the fragment from the address bar (so a reload doesn't try to join again).
static func clear_fragment() -> void:
	if is_web():
		JavaScriptBridge.eval("history.replaceState(null, '', window.location.pathname + window.location.search)", true)


## A query parameter of the page's address ("" when absent or outside a browser).
static func query(key: String) -> String:
	if is_web():
		var value: Variant = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('%s') || ''" % key, true)
		if value is String:
			return value
	return ""


static func copy(text: String) -> void:
	DisplayServer.clipboard_set(text)
