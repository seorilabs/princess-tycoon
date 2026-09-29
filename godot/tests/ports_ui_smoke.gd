extends SceneTree

const SAVE_PATH := "user://qa_ports_ui_smoke_save.json"

var _failures: Array[String] = []
var _passes := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[PORTS-UI] MainScreen integration")
	_prepare_test_save()
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "main scene 로드")
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var analytics: Variant = main.get("_analytics_port")
	var ads: Variant = main.get("_ad_port")
	var iap: Variant = main.get("_iap_port")
	var audio: Variant = main.get("_audio_port")
	_check(analytics != null and analytics.has_method("track"), "로컬 분석 포트 연결")
	_check(ads != null and ads.has_method("show_rewarded") and not ads.call("is_available"), "광고 no-op 포트 연결")
	_check(iap != null and iap.has_method("purchase") and not iap.call("is_available"), "IAP no-op 포트 연결")
	_check(audio != null and audio.has_method("play_cue"), "합성 오디오 포트 연결")
	_check(audio != null and audio.get("current_bgm_track") == &"silent", "무음 기본 BGM 훅 연결")
	if analytics != null:
		var events: Array = analytics.call("events")
		_check(events.size() >= 2, "시작·홈 로컬 분석 이벤트")
	if audio != null:
		main.call("_toggle_setting", false, "sound")
		_check(not bool(audio.get("enabled")), "UI sound=false 즉시 반영")
		main.call("_play_sfx", &"reward")
		_check(audio.get("last_requested_cue") != &"reward", "UI sound=false 재생 차단")
		main.call("_toggle_setting", true, "sound")
		main.call("_play_sfx", &"reward")
		_check(bool(audio.get("enabled")) and audio.get("last_requested_cue") == &"reward", "UI sound=true 합성 cue 요청")

	main.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		print("[FAIL] %s" % label)


func _finish() -> void:
	_cleanup_test_save()
	if _failures.is_empty():
		print("[PORTS-UI] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[PORTS-UI] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	quit(1)


func _prepare_test_save() -> void:
	_cleanup_test_save()
	ProjectSettings.set_setting("princess_tycoon/testing/save_path", SAVE_PATH)


func _cleanup_test_save() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_PATH)
	for suffix in ["", ".bak", ".tmp", ".corrupt"]:
		if FileAccess.file_exists(absolute + suffix):
			DirAccess.remove_absolute(absolute + suffix)
