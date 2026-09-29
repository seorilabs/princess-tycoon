extends SceneTree

const LocalAnalyticsPort = preload("res://src/ports/local_analytics_port.gd")
const NoOpAdPort = preload("res://src/ports/noop_ad_port.gd")
const NoOpIapPort = preload("res://src/ports/noop_iap_port.gd")
const SynthAudioPort = preload("res://src/ports/synth_audio_port.gd")

var _failures: Array[String] = []
var _passes := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[PORTS] Local hooks and synthesized audio")
	_test_analytics()
	_test_noop_commerce()
	await _test_audio()
	if _failures.is_empty():
		print("[PORTS] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[PORTS] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	for failure: String in _failures:
		print("[PORTS]   - %s" % failure)
	quit(1)


func _test_analytics() -> void:
	var analytics := LocalAnalyticsPort.new()
	_check(not bool(analytics.track(&"", {}).get("ok", true)), "빈 분석 이벤트 거부")
	var parameters := {"screen": "home", "nested": {"slot": 1}}
	var result: Dictionary = analytics.track(&"screen_view", parameters)
	parameters["screen"] = "mutated"
	var events: Array[Dictionary] = analytics.events()
	_check(bool(result.get("ok", false)), "로컬 분석 이벤트 기록")
	_check(events.size() == 1 and str(events[0].get("name", "")) == "screen_view", "이벤트 이름 보존")
	_check(str((events[0].get("parameters", {}) as Dictionary).get("screen", "")) == "home", "이벤트 매개변수 깊은 복사")
	_check(analytics.drain().size() == 1 and analytics.events().is_empty(), "분석 버퍼 drain")


func _test_noop_commerce() -> void:
	var ads := NoOpAdPort.new()
	var rewarded: Dictionary = ads.show_rewarded(&"offline_bonus")
	_check(not ads.is_available() and not bool(rewarded.get("ok", true)), "광고 no-op 비활성")
	_check(not bool(rewarded.get("rewardGranted", true)), "광고 no-op 보상 미지급")
	var iap := NoOpIapPort.new()
	var purchase: Dictionary = iap.purchase(&"starter_pack")
	_check(not iap.is_available() and not bool(purchase.get("ok", true)), "IAP no-op 비활성")
	_check(not bool(purchase.get("entitlementGranted", true)) and not iap.owns(&"starter_pack"), "IAP no-op 권한 미부여")


func _test_audio() -> void:
	var audio := SynthAudioPort.new()
	root.add_child(audio)
	await process_frame
	for cue: StringName in [SynthAudioPort.CUE_BUTTON, SynthAudioPort.CUE_REWARD, SynthAudioPort.CUE_FAILURE]:
		var stream: AudioStreamWAV = audio.get_cue_stream(cue)
		_check(stream != null and stream.data.size() > 100, "합성 파형 생성: %s" % String(cue))
	_check(audio.current_bgm_track == SynthAudioPort.SILENT_BGM, "기본 BGM silent 훅")
	audio.set_enabled(false)
	_check(not audio.play_reward() and audio.last_requested_cue == &"", "sound=false 시 효과음 차단")
	audio.set_enabled(true)
	var playback_result := audio.play_button()
	_check(audio.last_requested_cue == SynthAudioPort.CUE_BUTTON, "headless-safe 효과음 요청")
	_check(not playback_result if DisplayServer.get_name() == "headless" else true, "headless 오디오 장치 호출 생략")
	audio.queue_free()
	await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		print("[FAIL] %s" % label)
