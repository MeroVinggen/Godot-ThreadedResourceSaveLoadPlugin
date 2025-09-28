extends Node
class_name ThreadedResourceSaver

signal saveStarted(totalResources: int)
signal saveProgress(completedCount: int, totalResources: int, savedPath: String)
signal saveFinished(savedPaths: Array[String])
signal saveError(path: String, errorCode: Error)
signal becameIdle()

static var ignoreWarnings: bool = false

var _semaphore: Semaphore
var _mutex: Mutex
var _threads: Array[Thread] = []
# curently processing queue
var _activeQueue: Array[Array] = []
# queue awaiting for `start` call
# typing: Dictionary[save_path: String, save_params: Array]
#	any params with same save path will just override existed
#	so only the most recent remains to process
var _idleQueue: Dictionary = {}
# used to check for duplicates
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
var _savedPaths: Array[String] = []
var _verifyFilesAccess: bool = true
var _isStopping: bool = false
var _savingHasStarted: bool = false
var _currentThreadsAmount: int = 0
# flag for start calls during cleaning (stopping) stage
var _auto_start_on_ready: bool = false
var _auto_start_on_ready_thread_amount: int = 0


func _init() -> void:
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()


func is_idle() -> bool:
	_mutex.lock()
	var result = not _savingHasStarted
	_mutex.unlock()
	return result


func get_current_threads_amount() -> int:
	_mutex.lock()
	var result = _currentThreadsAmount
	_mutex.unlock()
	return result


# typing resources -> Array[{ resource: Resource, path: String }]
func add(resources: Array[Array]) -> ThreadedResourceSaver:
	_mutex.lock()
	
	for params in resources:
		if not (params[0] is Resource):
			push_error("invalid param value: \"{0}\", it should be a Resource, will be ignored".format([params[0]]))
			continue
			
		if params.size() == 0: 
			push_error("empty params array will be ignored")
			continue
		else:
			var resourcePathIsEmpty: bool = params[0].resource_path.strip_edges() == ""
			
			if params.size() == 1:
				if resourcePathIsEmpty:
					push_error("resource_path is empty and no save path param been provided, resource will be ignored")
					continue
				else:
					if not ThreadedResourceSaver.ignoreWarnings:
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
						if not ThreadedResourceSaver.ignoreWarnings:
							push_warning("save path param is empty, resource_path will be used instead: \"{0}\"".format([params[0].resource_path]))
						params[1] = params[0].resource_path

		_idleQueue[params[1]] = params
	
	_mutex.unlock()
	
	return self


func start(verifyFilesAccess: bool = false, threadsAmount: int = OS.get_processor_count() - 1) -> ThreadedResourceSaver:
	_mutex.lock()
	if _isStopping:
		push_warning("currently in the cleaning stage, the start will be delayed")
		_auto_start_on_ready = true
		_auto_start_on_ready_thread_amount = threadsAmount
		_mutex.unlock()
		return self
	
	_activeQueue.append_array(_idleQueue.values())
	_totalResourcesAmount += _idleQueue.size()
	
	if _totalResourcesAmount == 0:
		if not ThreadedResourceSaver.ignoreWarnings:
			push_warning("save queue is empty, immediate finish saving signal emission")
		call_deferred("emit_signal", "saveFinished", _savedPaths)
		_mutex.unlock()
		if _savingHasStarted:
			_stopSaveThreads.call_deferred()
		else:
			_clearDataAfterSave.call_deferred()
		return self
	
	if not _savingHasStarted:
		_savingHasStarted = true
		_verifyFilesAccess = verifyFilesAccess
		
		# Create thread pool for this saving session
		_initThreadPool(threadsAmount)
		
		call_deferred("emit_signal", "saveStarted", _totalResourcesAmount)
		
		for _i in range(_currentThreadsAmount):
			_semaphore.post.call_deferred()
	
	_idleQueue.clear()
	_mutex.unlock()
	
	return self


func _initThreadPool(threadsAmount: int) -> void:
	var actualThreadsNeeded = min(threadsAmount, _totalResourcesAmount)
	var thread: Thread
	for i in range(actualThreadsNeeded):
		thread = Thread.new()
		_threads.append(thread)
		thread.start(_saveThreadWorker)
	_currentThreadsAmount = actualThreadsNeeded


func _saveThreadWorker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		
		if _isStopping:
			_mutex.unlock()
			break
		
		if _activeQueue.is_empty():
			_mutex.unlock()
			continue
		
		var saveParams: Array = _activeQueue.pop_back()
		
		_mutex.unlock()
		
		var error: Error = ResourceSaver.save.callv(saveParams)
		
		_mutex.lock()
		if error == OK:
			_completedResourcesAmount += 1
			_savedPaths.append(saveParams[1])
			call_deferred(
				"emit_signal", 
				"saveProgress", 
				_completedResourcesAmount, 
				_totalResourcesAmount,
				saveParams[1]
			)
		else:
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "saveError", saveParams[1], error)
		
		var isSaveComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isSaveComplete:
			_mutex.unlock()
			_verifyFileReadinessAccess.call_deferred()
		else:
			_mutex.unlock()
			
			if not _activeQueue.is_empty():
				_semaphore.post()


func _verifyFileReadinessAccess() -> void:
	_mutex.lock()
	var savedPathsCopy: Array[String] = _savedPaths.duplicate()
	_mutex.unlock()
	
	if not _verifyFilesAccess:
		call_deferred("emit_signal", "saveFinished", savedPathsCopy)
		_stopSaveThreads.call_deferred()
		return
	
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
	if _isStopping:
		_mutex.unlock()
		return
	_isStopping = true
	_mutex.unlock()
	
	for _i in range(_currentThreadsAmount):
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
	_activeQueue.clear()
	_threads.clear()
	_savedPaths = []
	_totalResourcesAmount = 0
	_completedResourcesAmount = 0
	_failedResourcesAmount = 0
	_isStopping = false
	_savingHasStarted = false
	_currentThreadsAmount = 0
	_verifyFilesAccess = true
	
	if _idleQueue.is_empty():
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
		_isStopping = true
		
		# don't use separate func coz ref will be invalid
		for _i in range(_currentThreadsAmount):
			_semaphore.post()
		
		for thread in _threads:
			if thread.is_started():
				thread.wait_to_finish()
		
		_mutex.unlock()


# cleanup for singleton remove / plugin disabled etc.
func _exit_tree():
	if _savingHasStarted:
		_stopSaveThreads()
