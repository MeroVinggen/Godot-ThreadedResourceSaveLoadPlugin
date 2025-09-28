## doesn't filter duplicates by resiurce path param, godot itself candles the 
##	cache check for already loaded reses

extends Node
class_name ThreadedResourceLoader

signal loadStarted(totalResources: int)
# typing: resource_key -> key from _resourcePathToKeyMap
signal loadProgress(completedCount: int, totalResources: int, resource: Resource, resource_key: String)
# typing: loaded -> Dictionary[key: String, res: Resource]
# typing: failed -> Dictionary[key: String, path: String]
signal loadGroup(groupName: String, loaded: Dictionary, failed: Dictionary)
# typing: loadedFiles -> Dictionary[key: String, res: Resource]
signal loadFinished(loadedFiles: Dictionary)
signal loadError(path: String)
signal becameIdle()

static var ignoreWarnings: bool = false

var _semaphore: Semaphore
var _mutex: Mutex
var _threads: Array[Thread] = []
# curently processing queue
var _activeQueue: Array[Array] = []
# queue awaiting for `start` call
var _idleQueue: Array[Array] = []
var _totalResourcesAmount: int = 0
var _completedResourcesAmount: int = 0
var _failedResourcesAmount: int = 0
# typing: Dictionary[String, Resource]
var _loadedFiles: Dictionary = {}
var _isStopping: bool = false
var _loadingHasStarted: bool = false
var _currentThreadsAmount: int = 0
# if no key passed for resource - path will be used insetead (don't use resource_key 
#	to prevent confusion for reses with the same names)
#	clearing only in cleaning func (don't erase each loaded/failed res)
# typing: Dictionary[String, String]
var _resourcePathToKeyMap: Dictionary = {}
# flag for start calls during cleaning (stopping) stage
var _auto_start_on_ready: bool = false
var _auto_start_on_ready_thread_amount: int = 0
# typing: Dictionary[group_name: String, {loaded: Array[Resource], failed: Array[resource_path: String], finished: int = 0, total: int = 0, ignore_in_finished: bool}]
var _groups: Dictionary = {}
# like `_resourcePathToKeyMap` but for groups (to get res group on load/err)
#	forming in `add_group`
var _resourcePathToGroupMap: Dictionary = {}


func _init() -> void:
	_semaphore = Semaphore.new()
	_mutex = Mutex.new()


func is_idle() -> bool:
	_mutex.lock()
	var result = not _loadingHasStarted
	_mutex.unlock()
	return result


func get_current_threads_amount() -> int:
	_mutex.lock()
	var result = _currentThreadsAmount
	_mutex.unlock()
	return result


func add_group(group_name: String, resources: Array[Array], ignore_in_finished: bool = false):
	_mutex.lock()
	
	for params in resources:
		if _areParamsValid(params):
			_idleQueue.append(params)
			
			if not _groups.has(group_name):
				_groups[group_name] = {
					"loaded": {}, 
					"failed": {}, 
					"finished": 0, 
					"total": 0,
					"ignore_in_finished": ignore_in_finished
				}
			
			_groups[group_name].total += 1
			_resourcePathToKeyMap[params[0]] = _getResourceKey(params)
			_resourcePathToGroupMap[params[0]] = group_name
		
	
	_mutex.unlock()
	
	return self


func add(resources: Array[Array]) -> ThreadedResourceLoader:
	_mutex.lock()
	
	for params in resources:
		if _areParamsValid(params):
			_idleQueue.append(params)
			
			_resourcePathToKeyMap[params[0]] = _getResourceKey(params)
	
	_mutex.unlock()
	
	return self


func _getResourceKey(params: Array) -> String:
	var resource_key = params.pop_front()
	# if pased name is empty - use resource path
	if resource_key.is_empty():
		resource_key = params[0]
	
	return resource_key


func _areParamsValid(params: Array) -> bool:
	# not enough params
	if params.size() < 2: 
		push_error("too few arguments in params array, will be ignored")
		return false
	# key param has incorrect type 
	elif typeof(params[0]) != TYPE_STRING and typeof(params[0]) != TYPE_STRING_NAME:
		push_error("invalid param value: \"{0}\" for resource key, it should be a type of String or StringName, will be ignored".format([params[0]]))
		return false
	# path param has incorrect type or empty
	elif (typeof(params[1]) != TYPE_STRING and typeof(params[1]) != TYPE_STRING_NAME) or params[1].strip_edges() == "":
		push_error("invalid param value: \"{0}\" for resource path, it should be a non-empty String or StringName, will be ignored".format([params[1]]))
		return false
	# skip if key already exists
	elif params[0].strip_edges() != "" and _keyExist(params[0]):
		if not ThreadedResourceLoader.ignoreWarnings:
			push_warning("key \"{0}\" already exists, resource will be ignored".format(params[0]))
		return false
	
	return true


func _keyExist(key: String) -> bool:
	return _resourcePathToKeyMap.has(key) or _idleQueue.any(func(params: Array) -> bool: return params[0] == key)


func start(threadsAmount: int = OS.get_processor_count() - 1) -> ThreadedResourceLoader:
	_mutex.lock()
	if _isStopping:
		push_warning("currently in the cleaning stage, the start will be delayed")
		_auto_start_on_ready = true
		_auto_start_on_ready_thread_amount = threadsAmount
		_mutex.unlock()
		return self
	
	_activeQueue.append_array(_idleQueue)
	_totalResourcesAmount += _idleQueue.size()
	
	if _totalResourcesAmount == 0:
		if not ThreadedResourceLoader.ignoreWarnings:
			push_warning("load queue is empty, immediate finish loading signal emission")
		call_deferred("emit_signal", "loadFinished", _loadedFiles)
		_mutex.unlock()
		if _loadingHasStarted:
			_stopLoadThreads.call_deferred()
		else:
			_clearDataAfterLoad.call_deferred()
		return self
	
	if not _loadingHasStarted:
		_loadingHasStarted = true
	
		# Create thread pool for this loading session
		_initThreadPool(threadsAmount)
	
		call_deferred("emit_signal", "loadStarted", _totalResourcesAmount)
	
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
		thread.start(_loadThreadWorker)
	_currentThreadsAmount = actualThreadsNeeded


func _loadThreadWorker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		
		if _isStopping:
			_mutex.unlock()
			break
		
		if _activeQueue.is_empty():
			_mutex.unlock()
			continue
		
		var loadItem: Array = _activeQueue.pop_back()
		
		_mutex.unlock()
		
		var resource: Resource = ResourceLoader.load.callv(loadItem)
		
		_mutex.lock()
		if resource:
			_completedResourcesAmount += 1
			
			if _resourcePathToGroupMap.has(loadItem[0]):
				var group: Dictionary = _groups[_resourcePathToGroupMap[resource.resource_path]]
				group.loaded[_resourcePathToKeyMap[resource.resource_path]] = resource
				group.finished += 1
				
				if not group.ignore_in_finished:
					_loadedFiles[_resourcePathToKeyMap[resource.resource_path]] = resource
				
				if group.finished == group.total:
					call_deferred(
						"emit_signal", 
						"loadGroup", 
						_resourcePathToGroupMap[resource.resource_path],
						group.loaded, 
						group.failed,
					)
					_groups.erase(_resourcePathToGroupMap[resource.resource_path])
			else:
				_loadedFiles[_resourcePathToKeyMap[resource.resource_path]] = resource
			
			call_deferred(
				"emit_signal", 
				"loadProgress", 
				_completedResourcesAmount, 
				_totalResourcesAmount,
				resource,
				_resourcePathToKeyMap[resource.resource_path],
			)
		else:
			if _resourcePathToGroupMap.has(loadItem[0]):
				var group: Dictionary = _groups[_resourcePathToGroupMap[loadItem[0]]]
				group.failed[_resourcePathToKeyMap[loadItem[0]]] = loadItem[0]
				group.finished += 1
				
			_failedResourcesAmount += 1
			call_deferred("emit_signal", "loadError", loadItem[0])
		
		var isLoadComplete: bool = _completedResourcesAmount + _failedResourcesAmount >= _totalResourcesAmount
		
		if isLoadComplete:
			call_deferred("emit_signal", "loadFinished", _loadedFiles)
			_mutex.unlock()
			_stopLoadThreads.call_deferred()
		else:
			_mutex.unlock()
			
			if not _activeQueue.is_empty():
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
	
	for thread in _threads:
		# not checking for alive coz thread coud exit naturaly on finished the work
		# so closing all the threads been opened anyway
		if thread.is_started():
			thread.wait_to_finish()
	
	# ensure to cleanup only after threads were stopped 
	_clearDataAfterLoad()


func _clearDataAfterLoad() -> void:
	_mutex.lock()
	
	# Clear all data for next use
	_activeQueue.clear()
	_threads.clear()
	_loadedFiles = {}
	_totalResourcesAmount = 0
	_completedResourcesAmount = 0
	_failedResourcesAmount = 0
	_isStopping = false
	_loadingHasStarted = false
	_currentThreadsAmount = 0
	_resourcePathToKeyMap.clear()
	_resourcePathToGroupMap.clear()
	_groups.clear()
	
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
	if _loadingHasStarted:
		_stopLoadThreads()
