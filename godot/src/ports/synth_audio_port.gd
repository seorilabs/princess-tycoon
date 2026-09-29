class_name SynthAudioPort
extends Node

## 외부 파일 없이 짧은 16-bit PCM 효과음을 합성한다.
## BGM은 silent 훅이 기본이며, 나중에 합법적인 AudioStream을 주입할 수 있다.

signal cue_requested(cue: StringName)
signal bgm_requested(track_id: StringName)

const MIX_RATE := 22050
const CUE_BUTTON := &"button"
const CUE_REWARD := &"reward"
const CUE_FAILURE := &"failure"
const SILENT_BGM := &"silent"

var enabled := true
var current_bgm_track: StringName = SILENT_BGM
var last_requested_cue: StringName = &""

var _sfx_player: AudioStreamPlayer
var _bgm_player: AudioStreamPlayer
var _stream_cache: Dictionary = {}


func _ready() -> void:
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.name = "SynthSfxPlayer"
	_sfx_player.volume_db = -7.0
	add_child(_sfx_player)
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BgmHookPlayer"
	_bgm_player.volume_db = -12.0
	add_child(_bgm_player)
	play_bgm(SILENT_BGM)


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		if _sfx_player != null:
			_sfx_player.stop()
		if _bgm_player != null:
			_bgm_player.stop()


func play_button() -> bool:
	return play_cue(CUE_BUTTON)


func play_reward() -> bool:
	return play_cue(CUE_REWARD)


func play_failure() -> bool:
	return play_cue(CUE_FAILURE)


func play_cue(cue: StringName) -> bool:
	if not enabled:
		return false
	var stream := get_cue_stream(cue)
	if stream == null:
		return false
	last_requested_cue = cue
	cue_requested.emit(cue)
	# Headless에서는 파형 생성까지만 수행하고 오디오 장치 호출은 피한다.
	if DisplayServer.get_name() == "headless" or not is_inside_tree() or _sfx_player == null:
		return false
	_sfx_player.stream = stream
	_sfx_player.play()
	return true


func play_bgm(track_id: StringName = SILENT_BGM, stream: AudioStream = null) -> bool:
	current_bgm_track = track_id
	bgm_requested.emit(track_id)
	if _bgm_player != null:
		_bgm_player.stop()
	# silent 또는 stream 미주입은 의도된 무음 기본값이다.
	if not enabled or track_id == SILENT_BGM or stream == null:
		return false
	if DisplayServer.get_name() == "headless" or not is_inside_tree() or _bgm_player == null:
		return false
	_bgm_player.stream = stream
	_bgm_player.play()
	return true


func get_cue_stream(cue: StringName) -> AudioStreamWAV:
	if _stream_cache.has(cue):
		return _stream_cache[cue] as AudioStreamWAV
	var stream: AudioStreamWAV
	match cue:
		CUE_BUTTON:
			stream = _make_sequence([740.0], 0.045, 0.20, 20.0)
		CUE_REWARD:
			stream = _make_sequence([523.25, 659.25, 783.99], 0.075, 0.28, 9.0)
		CUE_FAILURE:
			stream = _make_sequence([392.0, 261.63], 0.105, 0.25, 7.0, true)
		_:
			return null
	_stream_cache[cue] = stream
	return stream


func _make_sequence(frequencies: Array[float], seconds_per_note: float, amplitude: float, decay: float, add_harmonic: bool = false) -> AudioStreamWAV:
	var note_samples := maxi(1, int(float(MIX_RATE) * seconds_per_note))
	var data := PackedByteArray()
	data.resize(note_samples * frequencies.size() * 2)
	for note_index: int in range(frequencies.size()):
		var phase := 0.0
		for sample_index: int in range(note_samples):
			var time := float(sample_index) / float(MIX_RATE)
			phase += TAU * frequencies[note_index] / float(MIX_RATE)
			var attack := clampf(time / 0.004, 0.0, 1.0)
			var tail := clampf(float(note_samples - 1 - sample_index) / float(maxi(1, int(MIX_RATE * 0.012))), 0.0, 1.0)
			var sample := sin(phase) * amplitude
			if add_harmonic:
				sample += sin(phase * 2.0) * amplitude * 0.18
			sample *= attack * exp(-time * decay) * tail
			_write_sample(data, note_index * note_samples + sample_index, sample)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav


func _write_sample(data: PackedByteArray, index: int, value: float) -> void:
	var sample_16 := int(clampf(value, -1.0, 1.0) * 32767.0)
	data[index * 2] = sample_16 & 0xFF
	data[index * 2 + 1] = (sample_16 >> 8) & 0xFF
