class_name RoomCrypto
extends RefCounted
## Seals text with a key made from the room code, so what travels through the public trackers (the
## WebRTC offers and answers, with the addresses in them) is unreadable and unforgeable for anyone without
## the code. AES-256 in CBC mode with a random IV, then an HMAC-SHA256 over IV and ciphertext
## (encrypt-then-MAC): a message that was changed, or sealed with another code, opens to "".
## The keys come from PBKDF2-HMAC-SHA256 (a few thousand rounds) of the code, cached per code.

const ROUNDS := 3000
const SALT := "rune-ascent-multiplayer/keys/v1"

static var _cache: Dictionary[String, Array] = {}


## base64(iv || ciphertext || mac).
static func seal(text: String, code: String) -> String:
	var keys := _keys(code)
	var iv := Crypto.new().generate_random_bytes(16)
	var padded := _pad(text.to_utf8_buffer())
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, keys[0], iv)
	var encrypted := aes.update(padded)
	aes.finish()
	var body := iv + encrypted
	var mac := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, keys[1], body)
	return Marshalls.raw_to_base64(body + mac)


## The text, or "" when `sealed` is not something this code sealed (or was tampered with).
static func open(sealed: String, code: String) -> String:
	if not _looks_base64(sealed):
		return ""
	var raw := Marshalls.base64_to_raw(sealed)
	if raw.size() < 16 + 16 + 32 or (raw.size() - 32) % 16 != 0 or raw.size() > 200000:
		return ""
	var keys := _keys(code)
	var body := raw.slice(0, raw.size() - 32)
	var mac := raw.slice(raw.size() - 32)
	if not _same(Crypto.new().hmac_digest(HashingContext.HASH_SHA256, keys[1], body), mac):
		return ""
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, keys[0], body.slice(0, 16))
	var plain := aes.update(body.slice(16))
	aes.finish()
	return _unpad(plain).get_string_from_utf8()


static func _looks_base64(text: String) -> bool:
	if text.length() < 88 or text.length() % 4 != 0 or text.length() > 270000:
		return false
	for character in text:
		if not (character.is_valid_identifier() or (character >= "0" and character <= "9") or character in ["+", "/", "="]):
			return false
	return true


static func _keys(code: String) -> Array:
	if not _cache.has(code):
		var derived := _pbkdf2(code.to_utf8_buffer(), SALT.to_utf8_buffer(), ROUNDS, 64)
		_cache[code] = [derived.slice(0, 32), derived.slice(32, 64)]
	return _cache[code]


## PBKDF2 with HMAC-SHA256.
static func _pbkdf2(password: PackedByteArray, salt: PackedByteArray, rounds: int, length: int) -> PackedByteArray:
	var crypto := Crypto.new()
	var output := PackedByteArray()
	var block := 1
	while output.size() < length:
		var counter := PackedByteArray([(block >> 24) & 255, (block >> 16) & 255, (block >> 8) & 255, block & 255])
		var u := crypto.hmac_digest(HashingContext.HASH_SHA256, password, salt + counter)
		var t := u.duplicate()
		for round_index in range(1, rounds):
			u = crypto.hmac_digest(HashingContext.HASH_SHA256, password, u)
			for index in t.size():
				t[index] = t[index] ^ u[index]
		output.append_array(t)
		block += 1
	return output.slice(0, length)


static func _pad(bytes: PackedByteArray) -> PackedByteArray:
	var count := 16 - bytes.size() % 16
	var padded := bytes.duplicate()
	for index in count:
		padded.append(count)
	return padded


static func _unpad(bytes: PackedByteArray) -> PackedByteArray:
	if bytes.is_empty():
		return bytes
	var count := bytes[bytes.size() - 1]
	if count < 1 or count > 16 or count > bytes.size():
		return PackedByteArray()
	return bytes.slice(0, bytes.size() - count)


## Compares without stopping at the first difference.
static func _same(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var difference := 0
	for index in a.size():
		difference |= a[index] ^ b[index]
	return difference == 0
