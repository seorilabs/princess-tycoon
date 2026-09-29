class_name LocalAnalyticsPort
extends RefCounted

## 네트워크 전송 없이 런타임 이벤트를 메모리에 보관하는 분석 훅이다.
## sequence만 사용하므로 게임의 결정성이나 저장된 RNG에 영향을 주지 않는다.

signal event_recorded(record: Dictionary)

const MAX_BUFFER_SIZE := 200

var _events: Array[Dictionary] = []
var _sequence := 0


func track(event_name: StringName, parameters: Dictionary = {}) -> Dictionary:
	var normalized_name := String(event_name).strip_edges()
	if normalized_name.is_empty():
		return {"ok": false, "reason": "empty_event_name"}
	_sequence += 1
	var record := {
		"sequence": _sequence,
		"name": normalized_name,
		"parameters": parameters.duplicate(true),
	}
	_events.append(record)
	while _events.size() > MAX_BUFFER_SIZE:
		_events.pop_front()
	event_recorded.emit(record.duplicate(true))
	return {"ok": true, "record": record.duplicate(true)}


func events() -> Array[Dictionary]:
	return _events.duplicate(true)


func drain() -> Array[Dictionary]:
	var drained := _events.duplicate(true)
	_events.clear()
	return drained


func clear() -> void:
	_events.clear()


func sequence() -> int:
	return _sequence
