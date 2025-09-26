extends Node
class_name ThreadedResourceLoader

signal loadStarted(totalResources: int)
# typing: resource_name -> key from _resesPathToNameMap
signal loadProgress(completedCount: int, totalResources: int, resource: Resource, resource_key: String)
# typing: loadedFiles -> Dictionary[String, Resource]
signal loadCompleted(loadedFiles: Dictionary)
signal loadError(path: String)
signal loadReady()

static var ignoreWarnings: bool = false

var _semaphore: Semaphore
var _mutex: Mutex
var _loadThreads: Array[Thread] = []
var _loadQueue: Array[Array] = []
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
# typing: Dictionary[String, Resource]
var _loadedFiles: Dictionary = {}
var _isStopping: bool = false
var _loadingHasStarted: bool = false
var _currentThreadsAmount: int = 0
# if no name passed for resource - path will be used insetead (don't use resource_name 
#	to prevent confusion for reses with the same names)
# typing: Dictionary[String, String]
var _resesPathToNameMap: Dictionary = {}


func _init() -> void:
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()


func add(resources: Array[Array]) -> ThreadedResourceLoader:
	_mutex.lock()
	if _loadingHasStarted:
		_mutex.unlock()
		push_error("loading has already started, current call ignored")
		return self
	
	for params in resources:
		if params.size() < 2: 
			push_error("too few arguments in params array, will be ignored")
			continue
		elif typeof(params[0]) != TYPE_STRING and typeof(params[0]) != TYPE_STRING_NAME:
			push_error("invalid param value: \"{0}\" for resource key, it should be a type of String or StringName, will be ignored".format([params[0]]))
			continue
		elif (typeof(params[1]) != TYPE_STRING and typeof(params[1]) != TYPE_STRING_NAME) or params[1].strip_edges() == "":
			push_error("invalid param value: \"{0}\" for resource path, it should be a non-empty String or StringName, will be ignored".format([params[1]]))
			continue
		
		_loadQueue.append(params)
	
	_totalResourcesAmount = _loadQueue.size()
	_mutex.unlock()
	
	return self


func start(threadsAmount: int = OS.get_processor_count() - 1) -> ThreadedResourceLoader:
	_mutex.lock()
	if _loadingHasStarted:
		_mutex.unlock()
		push_error("loading has already started, current call ignored")
		return self
	
	if _totalResourcesAmount == 0:
		if not ThreadedResourceLoader.ignoreWarnings:
			push_warning("load queue is empty, immediate finish loading signal emission")
		call_deferred("emit_signal", "loadCompleted", _loadedFiles)
		_mutex.unlock()
		_clearDataAfterLoad.call_deferred()
		return self
	
	_loadingHasStarted = true
	
	# Create thread pool for this loading session
	_initThreadPool(threadsAmount)
	_initResesPathToNameMap()
	
	call_deferred("emit_signal", "loadStarted", _totalResourcesAmount)
	
	for _i in range(_currentThreadsAmount):
		_semaphore.post.call_deferred()
	
	_mutex.unlock()
	
	return self


func _initThreadPool(threadsAmount: int) -> void:
	var actualThreadsNeeded = min(threadsAmount, _totalResourcesAmount)
	var thread: Thread
	for i in range(actualThreadsNeeded):
		thread = Thread.new()
		_loadThreads.append(thread)
		thread.start(_loadThreadWorker)
	_currentThreadsAmount = actualThreadsNeeded


func _initResesPathToNameMap() -> void:
	print(_loadQueue)
	var resource_name: String
	for loadItem in _loadQueue:
		resource_name = loadItem.pop_front()
		# if pased name is empty - use resource path
		if resource_name.is_empty():
			resource_name = loadItem[0]
		
		_resesPathToNameMap[loadItem[0]] = resource_name
	print(_loadQueue)


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
			_loadedFiles[_resesPathToNameMap[resource.resource_path]] = resource
			
			call_deferred(
				"emit_signal", 
				"loadProgress", 
				_completedResourcesAmount, 
				_totalResourcesAmount,
				resource,
				_resesPathToNameMap[resource.resource_path],
			)
		else:
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "loadError", loadItem[0])
		
		var isLoadComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isLoadComplete:
			call_deferred("emit_signal", "loadCompleted", _loadedFiles)
			_mutex.unlock()
			_stopLoadThreads.call_deferred()
		else:
			_mutex.unlock()
			
			if not isQueueEmpty:
				_semaphore.post()


# handle also the cleanup (_clearDataAfterLoad call at the end)
func _stopLoadThreads() -> void:
	_mutex.lock()
	if _isStopping:
		_mutex.unlock()
		return
	_isStopping = true
	_mutex.unlock()
	
	for _i in range(_currentThreadsAmount):
		_semaphore.post()
	
	for thread in _loadThreads:
		# not checking for alive coz thread coud exit naturaly on finished the work
		# so closing all the threads been opened anyway
		if thread.is_started():
			thread.wait_to_finish()
	
	# ensure to cleanup only after threads were stopped 
	_clearDataAfterLoad()


func _clearDataAfterLoad() -> void:
	_mutex.lock()
	
	# Clear all data for next use
	_loadQueue.clear()
	_loadThreads.clear()
	_loadedFiles = {}
	_totalResourcesAmount = 0
	_completedResourcesAmount = 0
	_failedResourcesAmount = 0
	_isStopping = false
	_loadingHasStarted = false
	_currentThreadsAmount = 0
	
	_mutex.unlock()
	
	loadReady.emit()


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
		
		for thread in _loadThreads:
			if thread.is_started():
				thread.wait_to_finish()


# cleanup for singleton remove / plugin disabled etc.
func _exit_tree():
	if _loadingHasStarted:
		_stopLoadThreads()
