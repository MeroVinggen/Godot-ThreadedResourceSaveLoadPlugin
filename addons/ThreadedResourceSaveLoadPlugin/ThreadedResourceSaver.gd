extends Node
class_name ThreadedResourceSaver

signal saveStarted(totalResources: int)
signal saveProgress(completedCount: int, totalResources: int, savedPath: String)
signal saveFinished(savedPaths: Array[String])
signal saveError(path: String, errorCode: Error)
signal becameIdle()

static var ignore_warnings: bool = false

var _semaphore: Semaphore
var _mutex: Mutex
var _threads: Array[Thread] = []
# currently processing queue
var _active_queue: Dictionary = {}
# type : Array[String]
var _active_queue_keys: Array
# queue awaiting for `start` call
# typing: Dictionary[save_path: String, save_params: Array]
#	any params with same save path will just override existed
#	so only the most recent remains to process
var _idle_queue: Dictionary = {}
# used to check for duplicates
var _total_resources_amount: int = 0
var _completed_resources_amount: int = 0
var _failed_resources_amount: int = 0
var _saved_paths: Array[String] = []
var _verify_files_access: bool = true
# is in cleaning stage
var _is_stopping: bool = false
# on saving finished - schedule stopping (cleaning)
var _awaiting_for_cleaning: bool = false
var _saving_has_started: bool = false
var _current_threads_amount: int = 0
# flag for `start` calls during stopping (cleaning) stage to auto process them when become idle
var _auto_start_on_ready: bool = false
var _auto_start_on_ready_thread_amount: int = 0


func _init() -> void:
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()


func is_idle() -> bool:
	_mutex.lock()
	var result = not _saving_has_started
	_mutex.unlock()
	return result


func get_current_threads_amount() -> int:
	_mutex.lock()
	var result = _current_threads_amount
	_mutex.unlock()
	return result


# typing resources -> Array[{ resource: Resource, path: String }]
func add(resources: Array[Array]) -> ThreadedResourceSaver:
	_mutex.lock()
	
	for params in resources:
		if params.size() == 0: 
			push_error("empty params array will be ignored")
			continue
		
		if not (params[0] is Resource):
			push_error("invalid param value: \"{0}\", it should be a Resource, will be ignored".format([params[0]]))
			continue
		else:
			var resourcePathIsEmpty: bool = params[0].resource_path.strip_edges() == ""
			
			if params.size() == 1:
				if resourcePathIsEmpty:
					push_error("resource_path is empty and no save path param been provided, resource will be ignored")
					continue
				else:
					if not ThreadedResourceSaver.ignore_warnings:
						push_warning("save path param is empty, resource_path will be used instead: \"{0}\"".format([params[0].resource_path]))
					params.append(params[0].resource_path)
			# params amount > 1
			else:
				if typeof(params[1]) != TYPE_STRING and typeof(params[1]) != TYPE_STRING_NAME:
					push_error("invalid save path param value: \"{0}\", it should be a type of String or StringName, resource will be ignored".format([params[1]]))
					continue
				
				var savePathParamIsEmpty: bool = params[1].strip_edges() == ""
				
				if savePathParamIsEmpty:
					if resourcePathIsEmpty:
						push_error("resource_path and save path param are both empty, resource will be ignored")
						continue
					else:
						if not ThreadedResourceSaver.ignore_warnings:
							push_warning("save path param is empty, resource_path will be used instead: \"{0}\"".format([params[0].resource_path]))
						params[1] = params[0].resource_path

		_idle_queue[params[1]] = params
	
	_mutex.unlock()
	
	return self


func start(verifyFilesAccess: bool = false, threadsAmount: int = OS.get_processor_count() - 1) -> ThreadedResourceSaver:
	_mutex.lock()
	
	# if already in stop stage
	if _is_stopping:
		push_warning("currently in the cleaning stage, the start will be delayed")
		_auto_start_on_ready = true
		_auto_start_on_ready_thread_amount = threadsAmount
		_mutex.unlock()
		return self
	
	# if stop scheduled - cancel
	if _awaiting_for_cleaning:
		_awaiting_for_cleaning = false
	
	_active_queue.merge(_idle_queue, true)
	_total_resources_amount = _active_queue.size()
	_active_queue_keys = _active_queue.keys()
	
	if _total_resources_amount == 0:
		if not ThreadedResourceSaver.ignore_warnings:
			push_warning("save queue is empty, immediate finish saving signal emission")
		
		if _saving_has_started:
			if not _awaiting_for_cleaning:
				_awaiting_for_cleaning = true
				_on_save_finished.call_deferred()
		else:
			_clearDataAfterSave.call_deferred()
		
		call_deferred("emit_signal", "saveFinished", _saved_paths)
		_mutex.unlock()
		return self
	
	if not _saving_has_started:
		_saving_has_started = true
		_verify_files_access = verifyFilesAccess
		
		# Create thread pool for this saving session
		_init_thread_pool(threadsAmount)
		
	call_deferred("emit_signal", "saveStarted", _total_resources_amount)
	
	for _i in range(_current_threads_amount):
		_semaphore.post.call_deferred()
	
	_idle_queue.clear()
	_mutex.unlock()
	
	return self


func _init_thread_pool(threadsAmount: int) -> void:
	var actualThreadsNeeded = min(threadsAmount, _total_resources_amount)
	var thread: Thread
	for i in range(actualThreadsNeeded):
		thread = Thread.new()
		_threads.append(thread)
		thread.start(_save_thread_worker)
	_current_threads_amount = actualThreadsNeeded


func _save_thread_worker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		
		if _is_stopping:
			_mutex.unlock()
			break
		
		if _active_queue_keys.is_empty():
			_mutex.unlock()
			continue
		
		var resource_path: String = _active_queue_keys.pop_back()
		var saveParams: Array = _active_queue[resource_path]
		_active_queue.erase(resource_path)
		
		_mutex.unlock()
		
		var error: Error = ResourceSaver.save.callv(saveParams)
		
		_mutex.lock()
		
		if error == OK:
			_completed_resources_amount += 1
			_saved_paths.append(resource_path)
			call_deferred(
				"emit_signal", 
				"saveProgress", 
				_completed_resources_amount, 
				_total_resources_amount,
				resource_path
			)
		else:
			_failed_resources_amount += 1
			call_deferred("emit_signal", "saveError", resource_path, error)
		
		var isSaveComplete: bool = _completed_resources_amount + _failed_resources_amount >= _total_resources_amount
		
		if isSaveComplete:
			if _verify_files_access:
				_verifyFileReadinessAccess.call_deferred()
			else:
				call_deferred("emit_signal", "saveFinished", _saved_paths)
				_awaiting_for_cleaning = true
				_on_save_finished.call_deferred()
		else:
			if not _active_queue_keys.is_empty():
				_semaphore.post()
				
		_mutex.unlock()


func _on_save_finished() -> void:
	# could be canceled by new `start`
	if _awaiting_for_cleaning:
		_stopSaveThreads()


func _verifyFileReadinessAccess() -> void:
	_mutex.lock()
	var savedPathsCopy: Array[String] = _saved_paths.duplicate()
	_mutex.unlock()
	
	var file: FileAccess
	for path in savedPathsCopy:
		file = FileAccess.open(path, FileAccess.READ)
		if file:
			file.close()
		else:
			call_deferred("emit_signal", "saveError", path, ERR_FILE_CANT_READ)
			_stopSaveThreads.call_deferred()
			return
	
	call_deferred("emit_signal", "saveFinished", savedPathsCopy)
	_stopSaveThreads.call_deferred()


# handle also the cleanup (_clearDataAfterSave call at the end)
func _stopSaveThreads() -> void:
	_mutex.lock()
	if _is_stopping:
		_mutex.unlock()
		return
	_is_stopping = true
	_mutex.unlock()
	
	for _i in range(_current_threads_amount):
		_semaphore.post()
	
	for thread in _threads:
		# not checking for alive coz thread could exit naturally on finished the work
		# so closing all the threads been opened anyway
		if thread.is_started():
			thread.wait_to_finish()
	
	# ensure to cleanup only after threads were stopped 
	_clearDataAfterSave()


func _clearDataAfterSave() -> void:
	_mutex.lock()
	
	# Clear all data for next use
	_active_queue.clear()
	_active_queue_keys.clear()
	_threads.clear()
	_saved_paths = []
	_total_resources_amount = 0
	_completed_resources_amount = 0
	_failed_resources_amount = 0
	_is_stopping = false
	_saving_has_started = false
	_current_threads_amount = 0
	_verify_files_access = true
	_awaiting_for_cleaning = false
	
	if _idle_queue.is_empty():
		_auto_start_on_ready = false
		_auto_start_on_ready_thread_amount = 0
	elif _auto_start_on_ready:
		call_deferred("start", _auto_start_on_ready_thread_amount)
		
	_mutex.unlock()
	
	becameIdle.emit()


# force threads cleanup on instance freed
# 	(preventing thread leaks if freed instance before it finished the job)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Force immediate thread cleanup when being deleted
		_mutex.lock()
		_is_stopping = true
		
		# don't use separate func coz ref will be invalid
		for _i in range(_current_threads_amount):
			_semaphore.post()
		
		for thread in _threads:
			if thread.is_started():
				thread.wait_to_finish()
		
		_mutex.unlock()


# cleanup for singleton remove / plugin disabled etc.
func _exit_tree():
	if _saving_has_started:
		_stopSaveThreads()
