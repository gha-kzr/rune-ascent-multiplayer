extends TestCase
## Invites as pasteable text: round trip, inside a link, and no trust in what comes back.


func _sample() -> Dictionary:
	var sdp := "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=ice-ufrag:abcd\r\na=ice-pwd:0123456789abcdef0123456789\r\na=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\na=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\n"
	return {"v": 1, "room": "k3x9", "host": 1, "for": 2, "offer": NetJson.stringify({"t": "offer", "s": sdp, "c": [["0", 0, "candidate:1 1 UDP 2122260223 192.168.1.20 52000 typ host"], ["0", 0, "candidate:2 1 UDP 1686052607 203.0.113.9 52000 typ srflx raddr 192.168.1.20 rport 52000"]]})}


func test_a_code_round_trips_and_stays_short_and_url_safe() -> void:
	var data := _sample()
	var code := InviteCodec.encode(data)
	assert_eq(InviteCodec.decode(code), data)
	assert_true(code.length() < 1100, "a pasteable size: %d characters" % code.length())
	for character in code:
		assert_true(character.to_lower() != character or character.to_upper() != character or "0123456789-_".contains(character), "URL-safe: %s" % character)


func test_a_whole_link_decodes_like_the_bare_code() -> void:
	var data := _sample()
	var code := InviteCodec.encode(data)
	var link := InviteCodec.link_for("https://example.github.io/rune-ascent-multiplayer/index.html#old=1", InviteCodec.JOIN_KEY, code)
	assert_eq(link, "https://example.github.io/rune-ascent-multiplayer/index.html#join=" + code)
	assert_eq(InviteCodec.decode(link), data)
	assert_eq(InviteCodec.decode("  " + code + "\n"), data, "spaces around it")
	assert_eq(InviteCodec.decode("https://x.io/#reply=" + code + "&other=1"), data)
	assert_eq(InviteCodec.decode("join=" + code), data, "just the fragment, as the page reads it")
	assert_eq(InviteCodec.decode("reply=" + code), data)


func test_garbage_decodes_to_nothing() -> void:
	for bad in ["", "   ", "hello world", "////", "AAAA", "!!!!", "eyJhIjoxfQ", "a".repeat(5000), "https://x.io/#join=", "%00%00"]:
		assert_eq(InviteCodec.decode(bad), {}, "rejects '%s'" % bad.left(20))


func test_a_code_that_claims_a_huge_size_is_refused_before_unpacking() -> void:
	var tiny := "{}".to_utf8_buffer().compress(FileAccess.COMPRESSION_DEFLATE)
	var base64 := Marshalls.raw_to_base64(tiny).replace("+", "-").replace("/", "_").replace("=", "")
	var checksum := InviteCodec._checksum(tiny)
	var honest := "R1%06x%04x%s" % [2, checksum, base64]
	assert_eq(InviteCodec.decode(honest), {}, "an empty object is not an invite")  # {} decodes to {}: same as nothing.
	var bomb := "R1%06x%04x%s" % [InviteCodec.MAX_DECODED + 1, checksum, base64]
	assert_eq(InviteCodec.decode(bomb), {})
	var lying := "R1%06x%04x%s" % [500, checksum, base64]
	assert_eq(InviteCodec.decode(lying), {}, "the size must match what unpacks")
