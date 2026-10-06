extends TestCase
## Room codes and the sealing of what goes through the public trackers.


func test_a_generated_code_is_twelve_characters_from_the_alphabet() -> void:
	var seen := {}
	for i in 20:
		var code := RoomCode.generate()
		assert_eq(code.length(), RoomCode.LENGTH)
		for character in code:
			assert_true(RoomCode.ALPHABET.contains(character))
		seen[code] = true
	assert_eq(seen.size(), 20, "no repeats")


func test_codes_are_read_from_what_players_type_or_paste() -> void:
	var code := "abcdefghjkmn"
	assert_eq(RoomCode.normalize("ABCD-EFGH-JKMN"), code)
	assert_eq(RoomCode.normalize(" abcd efgh jkmn "), code)
	assert_eq(RoomCode.normalize("https://x.io/game/#room=abcdefghjkmn"), code, "a link")
	assert_eq(RoomCode.normalize("https://x.io/game/?a=1#room=abcd-efgh-jkmn&b=2"), code)
	assert_eq(RoomCode.normalize("room=abcdefghjkmn"), code)
	for bad in ["", "abc", "abcdefghjkmnp", "abcdefghjkm0", "abcdefghjkm!", "ILOILOILOILO", "R1000012abcdef", "https://x.io/#join=abcdefghjkmn"]:
		assert_eq(RoomCode.normalize(bad), "", "not a code: %s" % bad)
	assert_eq(RoomCode.pretty(code), "abcd-efgh-jkmn")
	assert_eq(RoomCode.link_for("https://x.io/p/index.html#old", code), "https://x.io/p/index.html#room=abcdefghjkmn")


func test_the_room_name_on_the_tracker_is_twenty_bytes_and_hides_the_code() -> void:
	var hash := RoomCode.info_hash("abcdefghjkmn")
	assert_eq(hash.length(), 20)
	assert_eq(hash, RoomCode.info_hash("abcdefghjkmn"), "the same for everyone")
	assert_ne(hash, RoomCode.info_hash("abcdefghjkmp"))
	for character in hash:
		assert_true(character.unicode_at(0) < 256)
	assert_false(hash.contains("abcdefgh"))
	assert_ne(RoomCode.random_peer_id(), RoomCode.random_peer_id())
	assert_eq(RoomCode.random_peer_id().length(), 20)


func test_what_is_sealed_opens_with_the_same_code_only() -> void:
	var text := "the offer, with addresses 192.168.1.20 and unicode é ü"
	var sealed := RoomCrypto.seal(text, "abcdefghjkmn")
	assert_false(sealed.contains("addresses"), "not readable")
	assert_eq(RoomCrypto.open(sealed, "abcdefghjkmn"), text)
	assert_eq(RoomCrypto.open(sealed, "abcdefghjkmp"), "", "another code")
	assert_ne(RoomCrypto.seal(text, "abcdefghjkmn"), sealed, "a fresh IV each time")
	assert_eq(RoomCrypto.open(RoomCrypto.seal("", "abcdefghjkmn"), "abcdefghjkmn"), "", "empty text is fine")
	var long := "x".repeat(5000)
	assert_eq(RoomCrypto.open(RoomCrypto.seal(long, "abcdefghjkmn"), "abcdefghjkmn"), long)


func test_a_changed_or_forged_message_opens_to_nothing() -> void:
	var sealed := RoomCrypto.seal("hello", "abcdefghjkmn")
	var raw := Marshalls.base64_to_raw(sealed)
	for index in [0, 5, 16, 20, raw.size() - 1]:
		var changed := raw.duplicate()
		changed[index] = changed[index] ^ 1
		assert_eq(RoomCrypto.open(Marshalls.raw_to_base64(changed), "abcdefghjkmn"), "", "byte %d changed" % index)
	for bad in ["", "AAAA", "not base64!!", Marshalls.raw_to_base64(PackedByteArray([1, 2, 3])), Marshalls.raw_to_base64(raw.slice(0, 40))]:
		assert_eq(RoomCrypto.open(bad, "abcdefghjkmn"), "", "garbage")


func test_tracker_ids_are_always_twenty_printable_characters_that_survive_json() -> void:
	for i in 600:
		var ids := [RoomCode.random_peer_id(), RoomCode.info_hash(RoomCode.generate())]
		for id: String in ids:
			assert_eq(id.length(), 20)
			for character in id:
				assert_true(character.unicode_at(0) >= 32 and character.unicode_at(0) < 256)
			var back: Variant = NetJson.parse(NetJson.stringify({"id": id}))
			assert_eq(back["id"], id, "the same after JSON")
