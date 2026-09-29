class_name NoOpAdPort
extends RefCounted

## 실제 SDK를 연결하기 전까지 항상 안전하게 실패하는 광고 포트다.

const REASON := "ad_sdk_not_configured"


func is_available(_placement: StringName = &"") -> bool:
	return false


func show_rewarded(placement: StringName) -> Dictionary:
	return {
		"ok": false,
		"placement": String(placement),
		"rewardGranted": false,
		"reason": REASON,
	}


func show_interstitial(placement: StringName) -> Dictionary:
	return {
		"ok": false,
		"placement": String(placement),
		"shown": false,
		"reason": REASON,
	}


func hide_banner(placement: StringName = &"") -> Dictionary:
	return {
		"ok": true,
		"placement": String(placement),
		"shown": false,
		"reason": "already_hidden",
	}
