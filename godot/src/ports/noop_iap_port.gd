class_name NoOpIapPort
extends RefCounted

## 실제 스토어 결제 SDK를 연결하기 전까지 구매 권한을 부여하지 않는 포트다.

const REASON := "iap_sdk_not_configured"


func is_available() -> bool:
	return false


func products(_product_ids: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"ok": false, "products": [], "reason": REASON}


func purchase(product_id: StringName) -> Dictionary:
	return {
		"ok": false,
		"productId": String(product_id),
		"entitlementGranted": false,
		"reason": REASON,
	}


func restore_purchases() -> Dictionary:
	return {"ok": false, "restored": [], "reason": REASON}


func owns(_product_id: StringName) -> bool:
	return false
