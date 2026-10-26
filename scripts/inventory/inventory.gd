extends RefCounted
## Mô hình túi đồ: danh sách ô, mỗi ô là {} (trống) hoặc {"id": String, "count": int}.
## Không biết gì về giao diện; giao diện lắng nghe tín hiệu changed / item_added.

const ItemDefs := preload("res://scripts/inventory/item_defs.gd")

signal changed                                  # bất kỳ thay đổi nào của các ô
signal item_added(id: String, amount: int)      # vừa nhận thêm vật phẩm (để hiện thông báo +N)

var slots: Array = []


func _init(slot_count: int = -1) -> void:
	ItemDefs.ensure_loaded()
	var n := slot_count if slot_count > 0 else ItemDefs.SLOTS
	for i in n:
		slots.append({})


func count_of(id: String) -> int:
	var total := 0
	for s: Dictionary in slots:
		if not s.is_empty() and s["id"] == id:
			total += int(s["count"])
	return total


func has(id: String, amount: int = 1) -> bool:
	return count_of(id) >= amount


func used_slots() -> int:
	var n := 0
	for s: Dictionary in slots:
		if not s.is_empty():
			n += 1
	return n


## drops: [{"id": String, "count": int}, ...] có nhét hết được không (kiểm tra trước, không thay đổi túi).
func can_add_all(drops: Array) -> bool:
	var copy := _copy_slots()
	for d in drops:
		if _add_into(copy, d["id"], int(d["count"])) > 0:
			return false
	return true


## Thêm vật phẩm, trả về số lượng KHÔNG nhét được (0 = đã nhận đủ).
func add(id: String, amount: int) -> int:
	if amount <= 0 or not ItemDefs.has_item(id):
		return amount
	var leftover := _add_into(slots, id, amount)
	var added := amount - leftover
	if added > 0:
		item_added.emit(id, added)
		changed.emit()
	return leftover


## Bớt amount vật phẩm id (lấy từ các ô cuối trước). Không đủ thì không bớt gì và trả về false.
func remove(id: String, amount: int) -> bool:
	if amount <= 0 or count_of(id) < amount:
		return false
	var left := amount
	for i in range(slots.size() - 1, -1, -1):
		var s: Dictionary = slots[i]
		if s.is_empty() or s["id"] != id:
			continue
		var take := mini(left, int(s["count"]))
		_take_from_slot(i, take)
		left -= take
		if left <= 0:
			break
	changed.emit()
	return true


## Bớt tối đa amount vật phẩm ở ô index, trả về số đã bớt.
func remove_at(index: int, amount: int) -> int:
	if index < 0 or index >= slots.size() or (slots[index] as Dictionary).is_empty():
		return 0
	var take := mini(amount, int(slots[index]["count"]))
	_take_from_slot(index, take)
	changed.emit()
	return take


## Chuyển ô a sang ô b: cùng loại thì gộp (đến mức tối đa), khác loại hoặc ô b trống thì đổi chỗ.
func move_slot(a: int, b: int) -> void:
	if a == b or a < 0 or b < 0 or a >= slots.size() or b >= slots.size():
		return
	var sa: Dictionary = slots[a]
	var sb: Dictionary = slots[b]
	if sa.is_empty():
		return
	if not sb.is_empty() and sb["id"] == sa["id"]:
		var room := ItemDefs.max_stack(sa["id"]) - int(sb["count"])
		var moved := mini(room, int(sa["count"]))
		if moved > 0:
			sb["count"] = int(sb["count"]) + moved
			_take_from_slot(a, moved)
			changed.emit()
			return
	slots[a] = sb
	slots[b] = sa
	changed.emit()


## Tách amount vật phẩm ở ô index sang ô trống đầu tiên. Trả về chỉ số ô mới, -1 nếu không tách được (không còn ô trống, hoặc amount không nằm trong 1..count-1).
func split(index: int, amount: int) -> int:
	if index < 0 or index >= slots.size() or (slots[index] as Dictionary).is_empty():
		return -1
	var s: Dictionary = slots[index]
	if amount < 1 or amount >= int(s["count"]):
		return -1
	for i in slots.size():
		if (slots[i] as Dictionary).is_empty():
			slots[i] = {"id": s["id"], "count": amount}
			s["count"] = int(s["count"]) - amount
			changed.emit()
			return i
	return -1


## Gom các chồng cùng loại lại và xếp theo thứ tự khai báo trong items.json.
func sort_slots() -> void:
	var totals: Dictionary = {}
	for s: Dictionary in slots:
		if not s.is_empty():
			totals[s["id"]] = int(totals.get(s["id"], 0)) + int(s["count"])
	for i in slots.size():
		slots[i] = {}
	for id in ItemDefs.items:
		if totals.has(id):
			_add_into(slots, id, int(totals[id]))
	changed.emit()


func to_dict() -> Dictionary:
	var out: Array = []
	for s: Dictionary in slots:
		var entry: Variant = null
		if not s.is_empty():
			entry = [s["id"], int(s["count"])]
		out.append(entry)
	return {"slots": out}


## Nạp lại từ to_dict(); id không còn tồn tại bị bỏ, số lượng bị kẹp theo giới hạn hiện tại.
func from_dict(d: Dictionary) -> void:
	var arr: Array = d.get("slots", [])
	for i in slots.size():
		slots[i] = {}
		if i < arr.size() and arr[i] is Array and ItemDefs.has_item(str(arr[i][0])):
			var id := str(arr[i][0])
			slots[i] = {"id": id, "count": clampi(int(arr[i][1]), 1, ItemDefs.max_stack(id))}
	changed.emit()


func _take_from_slot(index: int, amount: int) -> void:
	var s: Dictionary = slots[index]
	s["count"] = int(s["count"]) - amount
	if int(s["count"]) <= 0:
		slots[index] = {}


func _copy_slots() -> Array:
	var out: Array = []
	for s: Dictionary in slots:
		out.append(s.duplicate())
	return out


## Nhét vào mảng ô arr: bù vào các chồng cùng loại trước, rồi tới ô trống. Trả về số lượng thừa.
static func _add_into(arr: Array, id: String, amount: int) -> int:
	var max_stack := ItemDefs.max_stack(id)
	var left := amount
	for i in arr.size():
		if left <= 0:
			break
		var s: Dictionary = arr[i]
		if not s.is_empty() and s["id"] == id and int(s["count"]) < max_stack:
			var add_n := mini(left, max_stack - int(s["count"]))
			s["count"] = int(s["count"]) + add_n
			left -= add_n
	for i in arr.size():
		if left <= 0:
			break
		if (arr[i] as Dictionary).is_empty():
			var add_n := mini(left, max_stack)
			arr[i] = {"id": id, "count": add_n}
			left -= add_n
	return left
