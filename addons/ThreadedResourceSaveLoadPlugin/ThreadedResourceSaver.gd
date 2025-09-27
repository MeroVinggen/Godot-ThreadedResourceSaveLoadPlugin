extends Node
class_name ThreadedResourceSaver

signal saveStarted(totalResources: int)
signal saveProgress(completedCount: int, totalResources: int)
signal saveCompleted(savedPaths: Array[String])
signal saveError(path: String, errorCode: Error)
signal saveReady()

static var ignoreWarnings: bool = false

var _semaphore: Semaphore
var _mutex: Mutex
var _saveThreads: Array[Thread] = []
var _saveQueue: Array[Array] = []
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
var _savedPaths: Array[String] = []
var _verifyFilesAccess: bool = true
var _isStopping: bool = false
var _savingHasStarted: bool = false
var _currentThreadsAmount: int = 0


func _init() -> void:
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()


func is_idle() -> bool:
	return not _savingHasStarted


func get_current_threads_amount() -> int:
	return _currentThreadsAmount

# typing resources -> Array[{ resource: Resource, path: String }]
func add(resources: Array[Array]) -> ThreadedResourceSaver:
	_mutex.lock()
	if _savingHasStarted:
		_mutex.unlock()
		push_error("saving has already started, current call ignored")
		return self
	
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
		
		_saveQueue.append(params)
	
	_mutex.unlock()
	
	return self


func start(verifyFilesAccess: bool = false, threadsAmount: int = OS.get_processor_count() - 1) -> ThreadedResourceSaver:
	_mutex.lock()
	if _savingHasStarted:
		_mutex.unlock()
		push_error("saving has already started, current call ignored")
		return self
	
	_totalResourcesAmount = _saveQueue.size()
	
	if _totalResourcesAmount == 0:
		if not ThreadedResourceSaver.ignoreWarnings:
			push_warning("save queue is empty, immediate finish saving signal emission")
		call_deferred("emit_signal", "saveCompleted", _savedPaths)
		_mutex.unlock()
		_clearDataAfterSave.call_deferred()
		return self
	
	_savingHasStarted = true
	_verifyFilesAccess = verifyFilesAccess
	
	# Create thread pool for this saving session
	_initThreadPool(threadsAmount)
	
	call_deferred("emit_signal", "saveStarted", _totalResourcesAmount)
	
	for _i in range(_currentThreadsAmount):
		_semaphore.post.call_deferred()
	
	_mutex.unlock()
	
	return self


func _initThreadPool(threadsAmount: int) -> void:
	var actualThreadsNeeded = min(threadsAmount, _totalResourcesAmount)
	var thread: Thread
	for i in range(actualThreadsNeeded):
		thread = Thread.new()
		_saveThreads.append(thread)
		thread.start(_saveThreadWorker)
	_currentThreadsAmount = actualThreadsNeeded


func _saveThreadWorker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		
		if _isStopping:
			_mutex.unlock()
			break
		
		if _saveQueue.is_empty():
			_mutex.unlock()
			continue
		
		var saveParams: Array = _saveQueue.pop_back()
		
		_mutex.unlock()
		
		var error: Error = ResourceSaver.save.callv(saveParams)
		
		_mutex.lock()
		if error == OK:
			_completedResourcesAmount += 1
			_savedPaths.append(saveParams[1])
			call_deferred("emit_signal", "saveProgress", _completedResourcesAmount, _totalResourcesAmount)
		else:
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "saveError", saveParams[1], error)
		
		var isSaveComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isSaveComplete:
			_mutex.unlock()
			_verifyFileReadinessAccess.call_deferred()
		else:
			_mutex.unlock()
			
			if not _saveQueue.is_empty():
				_semaphore.post()


func _verifyFileReadinessAccess() -> void:
	_mutex.lock()
	var savedPathsCopy: Array[String] = _savedPaths.duplicate()
	_mutex.unlock()
	
	if not _verifyFilesAccess:
		call_deferred("emit_signal", "saveCompleted", savedPathsCopy)
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
	
	call_deferred("emit_signal", "saveCompleted", savedPathsCopy)
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
	
	for thread in _saveThreads:
		# not checking for alive coz thread could exit naturally on finished the work
		# so closing all the threads been opened anyway
		if thread.is_started():
			thread.wait_to_finish()
	
	# ensure to cleanup only after threads were stopped 
	_clearDataAfterSave()


func _clearDataAfterSave() -> void:
	_mutex.lock()
	
	# Clear all data for next use
	_saveQueue.clear()
	_saveThreads.clear()
	_savedPaths = []
	_totalResourcesAmount = 0
	_completedResourcesAmount = 0
	_failedResourcesAmount = 0
	_isStopping = false
	_savingHasStarted = false
	_currentThreadsAmount = 0
	_verifyFilesAccess = true
	
	_mutex.unlock()
	
	saveReady.emit()


# force threads cleanup on instance freed
# 	(preventing thread leaks if freed instance before it finished the job)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Force immediate thread cleanup when being deleted
		_mutex.lock()
		_isStopping = true
		_mutex.unlock()
		
		# don't use separate func coz ref will be invalid
		for _i in range(_currentThreadsAmount):
			_semaphore.post()
		
		for thread in _saveThreads:
			if thread.is_started():
				thread.wait_to_finish()


# cleanup for singleton remove / plugin disabled etc.
func _exit_tree():
	if _savingHasStarted:
		_stopSaveThreads()
