class_name NetworkCrypto

const SEC_PREFIX := "SEC1|"
const VERSION := 1
const NONCE_SIZE := 16
const MAC_SIZE := 32
const MASTER_KEY_BASE64 := "vux6wYEw7jG+5bcgE3Y75s1RnwNy0OQ//EAUp7XNk2M="

static var _enc_key := PackedByteArray()
static var _mac_key := PackedByteArray()

static func encode_message(message: String) -> PackedByteArray:
	_ensure_keys()
	if _enc_key.size() == 0:
		return PackedByteArray()
	var nonce: PackedByteArray = Crypto.new().generate_random_bytes(NONCE_SIZE)
	var cipher: PackedByteArray = _stream_xor(_enc_key, nonce, message.to_utf8_buffer())
	var signed: PackedByteArray = PackedByteArray([VERSION])
	signed.append_array(nonce)
	signed.append_array(cipher)
	var mac: PackedByteArray = _hmac(signed)
	var payload: PackedByteArray = PackedByteArray()
	payload.append_array(signed)
	payload.append_array(mac)
	var encoded := Marshalls.raw_to_base64(payload)
	return (SEC_PREFIX + encoded).to_utf8_buffer()

static func decode_message(packet: PackedByteArray) -> String:
	_ensure_keys()
	if _enc_key.size() == 0:
		return ""
	var text := packet.get_string_from_utf8()
	if not text.begins_with(SEC_PREFIX):
		return ""
	var raw: PackedByteArray = Marshalls.base64_to_raw(text.substr(SEC_PREFIX.length()))
	if raw.size() < 1 + NONCE_SIZE + MAC_SIZE:
		return ""
	if raw[0] != VERSION:
		return ""
	var mac_start := raw.size() - MAC_SIZE
	var signed: PackedByteArray = _slice(raw, 0, mac_start)
	var mac: PackedByteArray = _slice(raw, mac_start, raw.size())
	var expected: PackedByteArray = _hmac(signed)
	if not _secure_equals(mac, expected):
		return ""
	var nonce: PackedByteArray = _slice(raw, 1, 1 + NONCE_SIZE)
	var cipher: PackedByteArray = _slice(raw, 1 + NONCE_SIZE, mac_start)
	var plain: PackedByteArray = _stream_xor(_enc_key, nonce, cipher)
	return plain.get_string_from_utf8()

static func _ensure_keys() -> void:
	if _enc_key.size() > 0:
		return
	var master: PackedByteArray = Marshalls.base64_to_raw(MASTER_KEY_BASE64)
	if master.size() != 32:
		push_error("NetworkCrypto: master key must be 32 bytes base64")
		return
	_enc_key = _derive_key(master, 0x01)
	_mac_key = _derive_key(master, 0x02)

static func _derive_key(master: PackedByteArray, tag: int) -> PackedByteArray:
	var data: PackedByteArray = PackedByteArray([tag])
	data.append_array(master)
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()

static func _hmac(data: PackedByteArray) -> PackedByteArray:
	var ctx: HMACContext = HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, _mac_key)
	ctx.update(data)
	return ctx.finish()

static func _secure_equals(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= int(a[i]) ^ int(b[i])
	return diff == 0

static func _stream_xor(key: PackedByteArray, nonce: PackedByteArray, input: PackedByteArray) -> PackedByteArray:
	var output: PackedByteArray = PackedByteArray()
	output.resize(input.size())
	var offset: int = 0
	var counter: int = 0
	while offset < input.size():
		var keystream: PackedByteArray = _keystream_block(key, nonce, counter)
		var chunk: int = int(min(keystream.size(), input.size() - offset))
		for i in range(chunk):
			output[offset + i] = input[offset + i] ^ keystream[i]
		offset += chunk
		counter += 1
	return output

static func _keystream_block(key: PackedByteArray, nonce: PackedByteArray, counter: int) -> PackedByteArray:
	var data: PackedByteArray = PackedByteArray()
	data.resize(nonce.size() + 8)
	for i in range(nonce.size()):
		data[i] = nonce[i]
	for i in range(8):
		var shift := (7 - i) * 8
		data[nonce.size() + i] = (counter >> shift) & 0xFF
	var ctx: HMACContext = HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, key)
	ctx.update(data)
	return ctx.finish()

static func _slice(data: PackedByteArray, start: int, end: int) -> PackedByteArray:
	var out := PackedByteArray()
	if end <= start:
		return out
	var size := end - start
	out.resize(size)
	var index := 0
	for i in range(start, end):
		out[index] = data[i]
		index += 1
	return out
