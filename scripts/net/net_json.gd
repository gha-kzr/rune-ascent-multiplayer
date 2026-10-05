class_name NetJson
extends RefCounted
## Messages travel as JSON text. JSON has one number type, so whole numbers come back as floats:
## parse() turns them into ints again, so the rest of the code can use plain ints.


static func stringify(message: Variant) -> String:
	return JSON.stringify(message)


## The parsed value with whole numbers as ints; null for text that isn't JSON.
static func parse(text: String) -> Variant:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return ints(parser.data)


static func ints(value: Variant) -> Variant:
	if value is float and is_equal_approx(value, roundf(value)) and absf(value) < 9.0e15:
		return int(value)
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(ints(item))
		return result
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = ints(value[key])
		return result
	return value
