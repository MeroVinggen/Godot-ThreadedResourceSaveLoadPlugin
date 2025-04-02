extends RefCounted
class_name ThreadedResourceSaver

signal saveStarted(totalResources: int)
signal saveProgress(completedCount: int, totalResources: int)
signal saveCompleted(savedPaths: Array[String])
signal saveError(path: String, errorCode: Error)

var MAX_THREADS: int
var _semaphore: Semaphore
var _mutex: Mutex
var _saveThreads: Array[Thread] = []
var _saveQueue: Array[Array] = []
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
var _savedPaths: Array[String] = []
var _verifyFilesAccess : bool = true
var _isStopping: bool = false
var _savingHasStarted: bool = false
var _selfRefToKeepAlive: ThreadedResourceSaver


func _init(verifyFilesAccess: bool = false, threadsAmount: int = OS.get_processor_count() - 1) -> void:
	_selfRefToKeepAlive = self
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()
	_verifyFilesAccess  = verifyFilesAccess
	MAX_THREADS = threadsAmount
	
	_initThreadPool()


func _initThreadPool() -> void:
	var thread: Thread
	for i in range(MAX_THREADS):
		thread = Thread.new()
		_saveThreads.append(thread)
		thread.start(_saveThreadWorker)


# typing
# resources: Array[{ resource: Resource, path: String }]
func add(resources: Array[Array]) -> ThreadedResourceSaver:
	_mutex.lock()
	if _savingHasStarted:
		_mutex.unlock()
		push_error("saving has already started, current call ignored")
		return self
	
	_saveQueue.append_array(resources)
	_totalResourcesAmount = _saveQueue.size()
	_mutex.unlock()
	
	return self


func start() -> ThreadedResourceSaver:
	_mutex.lock()
	if _savingHasStarted:
		_mutex.unlock()
		push_error("saving has already started, current call ignored")
		return self
	
	_savingHasStarted = true
	
	call_deferred("emit_signal", "saveStarted", _totalResourcesAmount)
	
	if _totalResourcesAmount == 0:
		push_warning("save queue is empty, immediate finish saving signal emission")
		call_deferred("emit_signal", "saveCompleted", _savedPaths)
		_mutex.unlock()
		return self
	
	for _i in range(min(MAX_THREADS, _totalResourcesAmount)):
		_semaphore.post.call_deferred()
	
	_mutex.unlock()
	
	return self


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
		var isQueueEmpty: bool = _saveQueue.is_empty()
		_mutex.unlock()
		
		var error: Error = ResourceSaver.save.callv(saveParams)
		
		_mutex.lock()
		var savePath: String = saveParams[1] if saveParams[1] != "" else saveParams[0].resource_path
		if error == OK:
			_completedResourcesAmount += 1
			_savedPaths.append(savePath)
			call_deferred("emit_signal", "saveProgress", _completedResourcesAmount, _totalResourcesAmount)
		else:
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "saveError", savePath, error)
		
		var isSaveComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isSaveComplete:
			_mutex.unlock()
			_verifyFileReadinessAccess.call_deferred()
		else:
			_mutex.unlock()
			
			if not isQueueEmpty:
				_semaphore.post()


func _verifyFileReadinessAccess() -> void:
	_mutex.lock()
	var savedPathsCopy: Array[String] = _savedPaths.duplicate()
	_mutex.unlock()
	
	if not _verifyFilesAccess:
		call_deferred("emit_signal", "saveCompleted", savedPathsCopy)
		_stopSaveThreads.call_deferred()
		_clearSelfRef.call_deferred()
		return
	
	var file: FileAccess
	for path in savedPathsCopy:
		file = FileAccess.open(path, FileAccess.READ)
		if file:
			file.close()
		else:
			call_deferred("emit_signal", "saveError", path, ERR_FILE_CANT_READ)
			_stopSaveThreads.call_deferred()
			_clearSelfRef.call_deferred()
			return
	
	call_deferred("emit_signal", "saveCompleted", savedPathsCopy)
	_stopSaveThreads.call_deferred()
	_clearSelfRef.call_deferred()


func _stopSaveThreads() -> void:
	_mutex.lock()
	if _isStopping:
		_mutex.unlock()
		return
	_isStopping = true
	_mutex.unlock()
	
	for _i in range(MAX_THREADS):
		_semaphore.post()
	
	for thread in _saveThreads:
		if thread.is_alive():
			thread.wait_to_finish()


func _clearSelfRef() -> void:
	_selfRefToKeepAlive = null


# force threads cleanup on instance freed
# 	(preventing thread leaks if freed instance before it finished the job)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_mutex.lock()
		_isStopping = true
		_mutex.unlock()
		
		# don't use separate func coz ref will be invalid
		for _i in range(MAX_THREADS):
			_semaphore.post()
		
		for thread in _saveThreads:
			if thread.is_started():
				thread.wait_to_finish()

