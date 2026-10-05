class_name InviteCodec
extends RefCounted
## Invites and replies as short text a player can paste anywhere: the data as JSON, compressed, in URL-safe
## base64 (no padding). A whole link (`https://…/#join=CODE`) or the bare code both work when decoding.
## Decoding never trusts its input: anything odd is an empty dictionary.

const MAX_DECODED := 200000
const JOIN_KEY := "join"
const REPLY_KEY := "reply"


## A code starts with "R1", the size of the data when unpacked (6 hex digits) and a checksum of the
## packed bytes (4 hex digits), so anything that isn't a code is refused before it is unpacked.
const HEADER := "R1"


static func encode(data: Dictionary) -> String:
	var bytes := NetJson.stringify(data).to_utf8_buffer()
	var packed := bytes.compress(FileAccess.COMPRESSION_DEFLATE)
	return "%s%06x%04x%s" % [HEADER, bytes.size(), _checksum(packed),
			Marshalls.raw_to_base64(packed).replace("+", "-").replace("/", "_").replace("=", "")]


static func _checksum(bytes: PackedByteArray) -> int:
	var low := 1
	var high := 0
	for value in bytes:
		low = (low + value) % 251
		high = (high + low) % 251
	return high * 256 + low


## The data, or {} when `text` isn't a code (a link around it is fine).
static func decode(text: String) -> Dictionary:
	var code := extract_code(text)
	if code.is_empty():
		return {}
	if code.length() < 13 or not code.begins_with(HEADER) or not code.substr(2, 10).is_valid_hex_number():
		return {}
	var size := code.substr(2, 6).hex_to_int()
	var checksum := code.substr(8, 4).hex_to_int()
	if size < 2 or size > MAX_DECODED:
		return {}
	var base64 := code.substr(12).replace("-", "+").replace("_", "/")
	while base64.length() % 4 != 0:
		base64 += "="
	var packed := Marshalls.base64_to_raw(base64)
	if packed.is_empty() or _checksum(packed) != checksum:
		return {}
	var bytes := packed.decompress(size, FileAccess.COMPRESSION_DEFLATE)
	if bytes.size() != size:
		return {}
	var parsed: Variant = NetJson.parse(bytes.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## The code inside a link (after `#join=` or `#reply=`), a fragment (`join=CODE`), or the trimmed text itself.
static func extract_code(text: String) -> String:
	var trimmed := text.strip_edges()
	for key in [JOIN_KEY, REPLY_KEY]:
		var marker := "%s=" % key
		if trimmed.begins_with(marker):
			trimmed = trimmed.substr(marker.length())
			break
		var at := trimmed.find("#" + marker)
		if at != -1:
			trimmed = trimmed.substr(at + 1 + marker.length())
			break
	var end := trimmed.find("&")
	if end != -1:
		trimmed = trimmed.left(end)
	for character in trimmed:
		if not (character.is_valid_identifier() or character == "-" or character == "_" or (character >= "0" and character <= "9")):
			return ""
	return trimmed


## A link for the invite: the page's own address (without any fragment) plus the code.
static func link_for(page_url: String, key: String, code: String) -> String:
	return "%s#%s=%s" % [page_url.get_slice("#", 0), key, code]
