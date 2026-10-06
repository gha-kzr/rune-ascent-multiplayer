class_name RoomCode
extends RefCounted
## The short secret that names a room on the public trackers and keys everything sent through them: 12
## characters (about 59 bits) from an alphabet without look-alikes, written in groups of four. Anyone who
## knows it can find the room and read what is sent to it, so it is shared like a password.

const ALPHABET := "abcdefghjkmnpqrstuvwxyz23456789"
const LENGTH := 12
const LINK_KEY := "room"


static func generate() -> String:
	var bytes := Crypto.new().generate_random_bytes(LENGTH)
	var text := ""
	for value in bytes:
		text += ALPHABET[value % ALPHABET.length()]
	return text


## The code as typed or pasted: lower case, without spaces, dashes or a link around it. "" when it isn't one.
static func normalize(text: String) -> String:
	var trimmed := text.strip_edges()
	var marker := "%s=" % LINK_KEY
	var at := trimmed.find(marker)
	if at != -1 and (at == 0 or trimmed[at - 1] in ["#", "&", "?"]):
		trimmed = trimmed.substr(at + marker.length())
		var end := trimmed.find("&")
		if end != -1:
			trimmed = trimmed.left(end)
	var clean := ""
	for character in trimmed.to_lower():
		if character in [" ", "-", "_"]:
			continue
		if not ALPHABET.contains(character):
			return ""
		clean += character
	return clean if clean.length() == LENGTH else ""


static func is_valid(text: String) -> bool:
	return not normalize(text).is_empty()


## "abcd-efgh-jkmn", for showing.
static func pretty(code: String) -> String:
	var groups: PackedStringArray = []
	for start in range(0, code.length(), 4):
		groups.append(code.substr(start, 4))
	return "-".join(groups)


static func link_for(page_url: String, code: String) -> String:
	return "%s#%s=%s" % [page_url.get_slice("#", 0), LINK_KEY, code]


## The 20-byte name of the room on a tracker: a hash of the code (the tracker never sees the code), as
## a "binary string" (one character per byte, as the tracker protocol wants it).
static func info_hash(code: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(("rune-ascent-multiplayer/room/" + code).to_utf8_buffer())
	return binary_string(hasher.finish().slice(0, 20))


## A fresh random 20-byte peer id as a binary string.
static func random_peer_id() -> String:
	return binary_string(Crypto.new().generate_random_bytes(20))


## One character per byte (32 to 255): no control characters, so the text is safe in any JSON, and no
## zero byte, which can't be a character. The same on every peer.
static func binary_string(bytes: PackedByteArray) -> String:
	var text := ""
	for value in bytes:
		text += String.chr(32 + value % 224)
	return text
