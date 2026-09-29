class_name BigValue
extends RefCounted

## A non-negative decimal floating point value stored as a normalized
## {mantissa, exponent} pair.  Economy code never needs to materialize the
## potentially enormous number as a native float.

const MAX_SIGNIFICANT_EXPONENT_GAP: int = 16
const MIN_MANTISSA: float = 1.0
const MAX_MANTISSA: float = 10.0


static func zero() -> Dictionary:
	return {"mantissa": 0.0, "exponent": 0}


static func one() -> Dictionary:
	return {"mantissa": 1.0, "exponent": 0}


static func from_number(value: Variant) -> Dictionary:
	if value is Dictionary:
		return normalize(value as Dictionary)
	if value is int or value is float:
		return from_float(float(value))
	if value is String:
		var text: String = (value as String).strip_edges()
		if text.is_valid_float() or text.is_valid_int():
			return from_float(text.to_float())
	return zero()


static func from_float(value: float) -> Dictionary:
	if value <= 0.0 or is_nan(value) or is_inf(value):
		return zero()
	var exponent: int = int(floor(log(value) / log(10.0)))
	var mantissa: float = value / pow(10.0, float(exponent))
	return normalize({"mantissa": mantissa, "exponent": exponent})


static func from_log10(log_value: float) -> Dictionary:
	if is_nan(log_value) or is_inf(log_value):
		return zero()
	var exponent: int = int(floor(log_value))
	var mantissa: float = pow(10.0, log_value - float(exponent))
	return normalize({"mantissa": mantissa, "exponent": exponent})


static func normalize(value: Dictionary) -> Dictionary:
	var mantissa: float = float(value.get("mantissa", 0.0))
	var exponent: int = int(value.get("exponent", 0))
	if is_nan(mantissa) or is_inf(mantissa) or mantissa <= 0.0:
		return zero()
	var shift: int = int(floor(log(absf(mantissa)) / log(10.0)))
	mantissa /= pow(10.0, float(shift))
	exponent += shift
	# Floating point rounding can leave an exact ten after the logarithmic shift.
	if mantissa >= MAX_MANTISSA:
		mantissa /= 10.0
		exponent += 1
	elif mantissa < MIN_MANTISSA:
		mantissa *= 10.0
		exponent -= 1
	if is_nan(mantissa) or is_inf(mantissa):
		return zero()
	return {"mantissa": mantissa, "exponent": exponent}


static func clone(value: Dictionary) -> Dictionary:
	var normalized: Dictionary = normalize(value)
	return {
		"mantissa": float(normalized["mantissa"]),
		"exponent": int(normalized["exponent"]),
	}


static func is_zero(value: Dictionary) -> bool:
	return float(value.get("mantissa", 0.0)) <= 0.0


static func is_valid(value: Dictionary) -> bool:
	var mantissa: float = float(value.get("mantissa", 0.0))
	var exponent_value: Variant = value.get("exponent", 0)
	if not (exponent_value is int or exponent_value is float):
		return false
	if is_nan(mantissa) or is_inf(mantissa) or mantissa < 0.0:
		return false
	if mantissa == 0.0:
		return int(exponent_value) == 0
	return mantissa >= MIN_MANTISSA and mantissa < MAX_MANTISSA


static func compare(left: Dictionary, right: Dictionary) -> int:
	var a: Dictionary = normalize(left)
	var b: Dictionary = normalize(right)
	if is_zero(a) and is_zero(b):
		return 0
	if is_zero(a):
		return -1
	if is_zero(b):
		return 1
	var exponent_a: int = int(a["exponent"])
	var exponent_b: int = int(b["exponent"])
	if exponent_a != exponent_b:
		return 1 if exponent_a > exponent_b else -1
	var mantissa_a: float = float(a["mantissa"])
	var mantissa_b: float = float(b["mantissa"])
	if is_equal_approx(mantissa_a, mantissa_b):
		return 0
	return 1 if mantissa_a > mantissa_b else -1


static func add(left: Dictionary, right: Dictionary) -> Dictionary:
	var a: Dictionary = normalize(left)
	var b: Dictionary = normalize(right)
	if is_zero(a):
		return clone(b)
	if is_zero(b):
		return clone(a)
	if compare(a, b) < 0:
		var swap: Dictionary = a
		a = b
		b = swap
	var gap: int = int(a["exponent"]) - int(b["exponent"])
	if gap >= MAX_SIGNIFICANT_EXPONENT_GAP:
		return clone(a)
	var mantissa: float = float(a["mantissa"]) + float(b["mantissa"]) * pow(10.0, -float(gap))
	return normalize({"mantissa": mantissa, "exponent": int(a["exponent"])})


static func subtract(left: Dictionary, right: Dictionary) -> Dictionary:
	var a: Dictionary = normalize(left)
	var b: Dictionary = normalize(right)
	if compare(a, b) <= 0:
		return zero()
	if is_zero(b):
		return clone(a)
	var gap: int = int(a["exponent"]) - int(b["exponent"])
	if gap >= MAX_SIGNIFICANT_EXPONENT_GAP:
		return clone(a)
	var mantissa: float = float(a["mantissa"]) - float(b["mantissa"]) * pow(10.0, -float(gap))
	return normalize({"mantissa": mantissa, "exponent": int(a["exponent"])})


static func multiply(left: Dictionary, right: Dictionary) -> Dictionary:
	var a: Dictionary = normalize(left)
	var b: Dictionary = normalize(right)
	if is_zero(a) or is_zero(b):
		return zero()
	return normalize({
		"mantissa": float(a["mantissa"]) * float(b["mantissa"]),
		"exponent": int(a["exponent"]) + int(b["exponent"]),
	})


static func multiply_float(value: Dictionary, factor: float) -> Dictionary:
	if factor <= 0.0 or is_nan(factor) or is_inf(factor) or is_zero(value):
		return zero()
	return from_log10(log10_value(value) + log(factor) / log(10.0))


static func divide_float(value: Dictionary, divisor: float) -> Dictionary:
	if divisor <= 0.0 or is_nan(divisor) or is_inf(divisor):
		return zero()
	return multiply_float(value, 1.0 / divisor)


static func pow_integer(value: Dictionary, exponent: int) -> Dictionary:
	if exponent == 0:
		return one()
	if exponent < 0 or is_zero(value):
		return zero()
	return from_log10(log10_value(value) * float(exponent))


static func pow_base(base: float, exponent: int) -> Dictionary:
	if exponent == 0:
		return one()
	if base <= 0.0 or exponent < 0 or is_nan(base) or is_inf(base):
		return zero()
	return from_log10((log(base) / log(10.0)) * float(exponent))


static func log10_value(value: Dictionary) -> float:
	var normalized: Dictionary = normalize(value)
	if is_zero(normalized):
		return -INF
	return log(float(normalized["mantissa"])) / log(10.0) + float(normalized["exponent"])


static func to_float(value: Dictionary, maximum: float = 1.0e300) -> float:
	var normalized: Dictionary = normalize(value)
	if is_zero(normalized):
		return 0.0
	var max_log: float = log(maximum) / log(10.0)
	var value_log: float = log10_value(normalized)
	if value_log >= max_log:
		return maximum
	if value_log < -307.0:
		return 0.0
	return float(normalized["mantissa"]) * pow(10.0, float(normalized["exponent"]))


static func ratio_clamped(numerator: Dictionary, denominator: Dictionary, maximum: float = 1.0e6) -> float:
	if is_zero(numerator):
		return 0.0
	if is_zero(denominator):
		return maximum
	var log_ratio: float = log10_value(numerator) - log10_value(denominator)
	if log_ratio >= log(maximum) / log(10.0):
		return maximum
	if log_ratio <= -16.0:
		return 0.0
	return pow(10.0, log_ratio)


static func format_short(value: Dictionary, decimals: int = 2) -> String:
	var normalized: Dictionary = normalize(value)
	if is_zero(normalized):
		return "0"
	var exponent: int = int(normalized["exponent"])
	var mantissa: float = float(normalized["mantissa"])
	var suffixes: Array[String] = ["", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc"]
	if exponent < 3:
		var small: float = to_float(normalized)
		return ("%.*f" % [decimals, small]).trim_suffix("0").trim_suffix(".")
	var group: int = int(floor(float(exponent) / 3.0))
	if group < suffixes.size():
		var scaled: float = mantissa * pow(10.0, float(exponent - group * 3))
		return ("%.*f%s" % [decimals, scaled, suffixes[group]]).trim_suffix("0").trim_suffix(".")
	return "%.*fe%d" % [decimals, mantissa, exponent]
