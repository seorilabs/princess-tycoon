class_name DeterministicRNG
extends RefCounted

## Counter-based deterministic random helpers.  The authoritative stream lives
## in state.seed/state.rngCounter; derived content uses local counters so that
## serializing generated content never changes future gameplay randomness.

const MODULUS: int = 2147483647
const MULTIPLIER_A: int = 48271
const MULTIPLIER_B: int = 69621


static func normalize_seed(seed_value: int) -> int:
	var normalized: int = seed_value % (MODULUS - 1)
	if normalized < 0:
		normalized += MODULUS - 1
	return normalized + 1


static func stable_string_hash(text: String) -> int:
	var result: int = 216613626 % MODULUS
	for index: int in range(text.length()):
		result = (result * 131 + text.unicode_at(index) + 17) % MODULUS
	return result


static func mix(seed_value: int, counter: int, salt: Variant = "") -> int:
	var seed_part: int = normalize_seed(seed_value)
	var counter_part: int = (counter % MODULUS + MODULUS) % MODULUS
	var salt_part: int = stable_string_hash(str(salt))
	var value: int = (seed_part + counter_part * MULTIPLIER_A + salt_part) % MODULUS
	value = (value * MULTIPLIER_B + 12345) % MODULUS
	value = (value * MULTIPLIER_A + salt_part * 31 + 97) % MODULUS
	return value


static func stable_hash(seed_value: int, counter: int, salt: Variant = "") -> int:
	return mix(seed_value, counter, salt)


static func derive_seed(seed_value: int, world_tier: int, season_index: int, slot_kind: String) -> int:
	return mix(seed_value, world_tier * 1000003 + season_index * 1009, slot_kind)


static func next_u32(state: Dictionary, salt: Variant = "") -> int:
	var counter: int = int(state.get("rngCounter", 0))
	var value: int = mix(int(state.get("seed", 1)), counter, salt)
	state["rngCounter"] = counter + 1
	return value


static func next_float(state: Dictionary, minimum: float = 0.0, maximum: float = 1.0, salt: Variant = "") -> float:
	if maximum <= minimum:
		return minimum
	var unit: float = float(next_u32(state, salt)) / float(MODULUS - 1)
	return lerpf(minimum, maximum, unit)


static func range_int(state: Dictionary, minimum: int, maximum_inclusive: int, salt: Variant = "") -> int:
	if maximum_inclusive <= minimum:
		return minimum
	var span: int = maximum_inclusive - minimum + 1
	return minimum + next_u32(state, salt) % span


static func value_at(seed_value: int, counter: int, minimum: float = 0.0, maximum: float = 1.0, salt: Variant = "") -> float:
	if maximum <= minimum:
		return minimum
	var unit: float = float(mix(seed_value, counter, salt)) / float(MODULUS - 1)
	return lerpf(minimum, maximum, unit)


static func challenge_jitter(seed_value: int, absolute_completion_slot: int, activity_id: String, minimum: float, maximum: float) -> float:
	# Challenge outcomes are isolated from unrelated growth/event RNG calls so
	# the generator and reducer can evaluate the same scheduled attempt exactly.
	return value_at(seed_value, absolute_completion_slot, minimum, maximum, "challenge_jitter:%s" % activity_id)


static func weighted_index(state: Dictionary, weights: Array[float], salt: Variant = "") -> int:
	if weights.is_empty():
		return -1
	var total: float = 0.0
	for weight: float in weights:
		total += maxf(0.0, weight)
	if total <= 0.0:
		return range_int(state, 0, weights.size() - 1, salt)
	var roll: float = next_float(state, 0.0, total, salt)
	var cursor: float = 0.0
	for index: int in range(weights.size()):
		cursor += maxf(0.0, weights[index])
		if roll <= cursor:
			return index
	return weights.size() - 1


static func weighted_index_at(seed_value: int, counter: int, weights: Array[float], salt: Variant = "") -> int:
	if weights.is_empty():
		return -1
	var total: float = 0.0
	for weight: float in weights:
		total += maxf(0.0, weight)
	if total <= 0.0:
		return mix(seed_value, counter, salt) % weights.size()
	var roll: float = value_at(seed_value, counter, 0.0, total, salt)
	var cursor: float = 0.0
	for index: int in range(weights.size()):
		cursor += maxf(0.0, weights[index])
		if roll <= cursor:
			return index
	return weights.size() - 1
