extends RefCounted
class_name ThreadedResourceLoader

signal loadStarted(totalResources: int)
signal loadProgress(completedCount: int, totalResources: int)
signal loadCompleted(loadedFiles: Array[Resource])
signal loadError(path: String)

static var ignoreWarnings: bool = false

var MAX_THREADS: int
var _semaphore: Semaphore
var _mutex: Mutex
var _loadThreads: Array[Thread] = []
var _loadQueue: Array[Array] = []
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
var _loadedFiles: Array[Resource] = []
var _isStopping: bool = false
var _loadingHasStarted: bool = false
var _selfRefToKeepAlive: ThreadedResourceLoader


func _init(threadsAmount: int = OS.get_processor_count() - 1) -> void:
	_selfRefToKeepAlive = self
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()
	MAX_THREADS = threadsAmount
	
	_initThreadPool()


func _initThreadPool() -> void:
	var thread: Thread
	for i in range(MAX_THREADS):
		thread = Thread.new()
		_loadThreads.append(thread)
		thread.start(_loadThreadWorker)


func add(resources: Array[Array]) -> ThreadedResourceLoader:
	_mutex.lock()
	if _loadingHasStarted:
		_mutex.unlock()
		push_error("loading has already started, current call ignored")
		return self
	
	for params in resources:
		if params.size() == 0: 
			push_error("empty params array will be ignored")
			continue
		elif typeof(params[0]) != TYPE_STRING or params[0].strip_edges() == "":
			push_error("invalid param value: \"{0}\", it should be a non empty string, will be ignored".format([params[0]]))
			continue
		
		_loadQueue.append(params)
	
	_totalResourcesAmount = _loadQueue.size()
	_mutex.unlock()
	
	return self


func start() -> ThreadedResourceLoader:
	_mutex.lock()
	if _loadingHasStarted:
		_mutex.unlock()
		push_error("loading has already started, current call ignored")
		return self
	
	_loadingHasStarted = true
	
	call_deferred("emit_signal", "loadStarted", _totalResourcesAmount)
	
	if _totalResourcesAmount == 0:
		if not ThreadedResourceSaver.ignoreWarnings:
			push_warning("load queue is empty, immediate finish loading signal emission")
		call_deferred("emit_signal", "loadCompleted", _loadedFiles)
		_mutex.unlock()
		return self
	
	for _i in range(min(MAX_THREADS, _totalResourcesAmount)):
		_semaphore.post.call_deferred()
	
	_mutex.unlock()
	
	return self


func _loadThreadWorker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		
		if _isStopping:
			_mutex.unlock()
			break
		
		if _loadQueue.is_empty():
			_mutex.unlock()
			continue
		
		var loadItem: Array = _loadQueue.pop_back()
		var isQueueEmpty: bool = _loadQueue.is_empty()
		_mutex.unlock()
		
		var resource: Resource = ResourceLoader.load.callv(loadItem)
		
		_mutex.lock()
		if resource:
			_completedResourcesAmount += 1
			_loadedFiles.append(resource)
			call_deferred("emit_signal", "loadProgress", _completedResourcesAmount, _totalResourcesAmount)
		else:
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "loadError", loadItem[0])
		
		var isLoadComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isLoadComplete:
			call_deferred("emit_signal", "loadCompleted", _loadedFiles)
			_mutex.unlock()
			_stopLoadThreads.call_deferred()
			_clearSelfRef.call_deferred()
		else:
			_mutex.unlock()
			
			if not isQueueEmpty:
				_semaphore.post()


func _stopLoadThreads() -> void:
	_mutex.lock()
	if _isStopping:
		_mutex.unlock()
		return
	_isStopping = true
	_mutex.unlock()
	
	for _i in range(MAX_THREADS):
		_semaphore.post()
	
	for thread in _loadThreads:
		if thread.is_alive():
			thread.wait_to_finish()


func _clearSelfRef() -> void:
	_selfRefToKeepAlive = null


# force threads cleanup on instance freed
# 	(preventing thread leaks if freed instance before it finished the job)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Force immediate thread cleanup when being deleted
		_mutex.lock()
		_isStopping = true
		_mutex.unlock()
		
		# don't use separate func coz ref will be invalid
		for _i in range(MAX_THREADS):
			_semaphore.post()
		
		for thread in _loadThreads:
			if thread.is_started():
				thread.wait_to_finish()
