extends Node

signal connected
signal disconnected
signal connect_failed(reason: String)
signal message_received(message: Dictionary)

var _socket := WebSocketPeer.new()
var _status := "idle"

func connect_to(url: String) -> void:
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = 4 * 1024 * 1024
	_socket.outbound_buffer_size = 4 * 1024 * 1024
	_status = "connecting"
	var error := _socket.connect_to_url(url)
	if error != OK:
		_status = "closed"
		connect_failed.emit("Could not start the connection (%s)." % error)

func _process(_delta: float) -> void:
	if _status == "idle" or _status == "closed":
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if _status != "open":
				_status = "open"
				connected.emit()
			while _socket.get_available_packet_count() > 0:
				var packet := _socket.get_packet()
				var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					message_received.emit(parsed as Dictionary)
		WebSocketPeer.STATE_CLOSED:
			var was_connecting := _status == "connecting"
			_status = "closed"
			if was_connecting:
				connect_failed.emit("Could not reach the server.")
			else:
				disconnected.emit()

func send_message(message: Dictionary) -> bool:
	if not is_open():
		return false
	return _socket.send_text(JSON.stringify(message)) == OK

func is_open() -> bool:
	return _status == "open" and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN

func is_connecting() -> bool:
	return _status == "connecting"

func close_socket() -> void:
	_status = "closed"
	_socket.close()

func debug_drop() -> void:
	_socket.close()
