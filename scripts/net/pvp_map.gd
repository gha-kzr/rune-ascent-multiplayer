class_name PvpMap
extends RefCounted
## A map for a PvP match, from the same shapes as the tower's maps (MapShapes: open field, mountain,
## crater, islands, canyon, ruins) but fair: the board is symmetric under a half turn, with a 3 x 3
## start zone for each side (side A is the map's `p` cells, side B its `e` cells) a walk apart. Fully
## determined by the seed, so every peer draws the same map from the three numbers they share.

const ZONE_CELLS := 9
const ATTEMPTS := 40
## Fewest MP between a cell of one zone and the other zone.
const MIN_DISTANCE := 6
const MIN_SIZE := 10
const MAX_SIZE := 18


## The typology's shape on a `size` x `size` board (clamped to MIN_SIZE..MAX_SIZE).
static func generate(map_seed: int, typology: MapTypology, size: int) -> MapData:
	size = clampi(size, MIN_SIZE, MAX_SIZE)
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	if typology == null:
		typology = MapTypology.new()
	for attempt in ATTEMPTS:
		var map := _attempt(rng, typology, size)
		if map != null and MapGenerator.is_playable(map, ZONE_CELLS, MIN_DISTANCE):
			return map
	push_warning("PvpMap: no valid map in %d attempts; using an open one" % ATTEMPTS)
	return _open_map(size)


static func _attempt(rng: RandomNumberGenerator, typology: MapTypology, size: int) -> MapData:
	var field := MapShapes.build(rng, typology, Vector2i(size, size))
	# Half of the board is the mirror image of the other half (a half turn). Heights first, then the
	# smoothing, which depends only on the heights, so it keeps the symmetry.
	for y in size:
		for x in size:
			if y * size + x < size * size / 2:
				var opposite := _opposite(Vector2i(x, y), size)
				field.heights[opposite.y][opposite.x] = field.heights[y][x]
				field.marks[opposite.y][opposite.x] = field.marks[y][x]
	MapShapes._smooth(field)
	var zone_a := _zone(Vector2i(size / 2, size - 2))
	var zone_b: Array[Vector2i] = []
	for cell in zone_a:
		zone_b.append(_opposite(cell, size))
	for cell in zone_a + zone_b:
		field.marks[cell.y][cell.x] = ""
	MapShapes.connect_ground(field, zone_a[4])
	# A bridge opened on one side opens on the other, so the board stays symmetric.
	for y in size:
		for x in size:
			var opposite := _opposite(Vector2i(x, y), size)
			if field.marks[y][x].is_empty() or field.marks[opposite.y][opposite.x].is_empty():
				field.marks[y][x] = ""
				field.marks[opposite.y][opposite.x] = ""
	return _to_map(field, zone_a, zone_b)


static func _opposite(cell: Vector2i, size: int) -> Vector2i:
	return Vector2i(size - 1 - cell.x, size - 1 - cell.y)


static func _zone(center: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			cells.append(center + Vector2i(dx, dy))
	return cells


static func _to_map(field: MapShapes.Field, zone_a: Array[Vector2i], zone_b: Array[Vector2i]) -> MapData:
	var lines: Array[String] = []
	for y in field.size.y:
		var tokens: Array[String] = []
		for x in field.size.x:
			var cell := Vector2i(x, y)
			var token := field.marks[y][x]
			if token == "#" and field.heights[y][x] > 0:
				token = "%d#" % field.heights[y][x]
			if token.is_empty() or cell in zone_a or cell in zone_b:
				token = str(field.heights[y][x])
				if cell in zone_a:
					token += MapData.PLAYER_SPAWN
				elif cell in zone_b:
					token += MapData.ENEMY_SPAWN
			tokens.append(token)
		lines.append(" ".join(tokens))
	var map := MapData.new()
	map.layout = "\n".join(lines)
	return map


## A flat board with the two zones, always valid.
static func _open_map(size: int) -> MapData:
	var field := MapShapes.Field.new(Vector2i(size, size))
	var zone_a := _zone(Vector2i(size / 2, size - 2))
	var zone_b: Array[Vector2i] = []
	for cell in zone_a:
		zone_b.append(_opposite(cell, size))
	return _to_map(field, zone_a, zone_b)
