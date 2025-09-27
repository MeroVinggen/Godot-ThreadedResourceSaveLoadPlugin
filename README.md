<p align="center">
  <img src="./icon.svg" height="100" alt="Godot-ProjectileOnCurve2DPlugin Icon"/>
</p>

<h1 align="center">
  Godot ThreadedResourceSaveLoad Plugin
</h1>

<p align="center">
  <a href="https://ko-fi.com/I2I31KH5HB" target="_blank">
	<img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support me on Ko-fi"/>
  </a>
</p>

<h2 align="center">
  <a href="#file-saving"> File saving </a>
  |
  <a href="#file-loading"> File loading </a>
</h2>

<p align="center">
  <img src="./demo-record.gif" height="350" alt="demo record"/>
</p>

## See my other plugins

- [ProjectileOnCurve2D ](https://github.com/MeroVinggen/Godot-ProjectileOnCurve2DPlugin)
- [	
Vector2 editor ](https://github.com/MeroVinggen/Godot-Vector2ArrayEditorPlugin)
- [Android Internet Connection State](https://github.com/MeroVinggen/Godot-AndroidInternetConnectionStatePlugin)

## About

This plugin allows you to save/load resources <b>fast</b> in the background using threads, preventing the main thread freezes and handle the save/load operations using signals.

> [!IMPORTANT]
> This is not the final solution for save/load processing in your project, but a wrapper for the native ResourceSaver and ResourceLoader, allowing them to be used in parallel. You may use it directly or build your save/load managers(modules) around it to suit your needs.


## Features

- Adjusting threads amount to use per task
- progress/errors/start/complete signals 
- optional files access verification after save
- batching for resources saving 
- easy resources access on multiple resource load
- easy to use, no additional config needed
  

## Requirements 

- Godot 4.1 or higher


## Installation

- Open the `AssetLib` tab in Godot with your project open
- Search for `ThreadedResourceSaveLoad` plugin and install the plugin by Mero
- Open Project -> Project Settings -> Plugins Tab and enable the plugin `ThreadedResourceSaveLoad`
- Done!


## Usage

> [!WARNING]
> Make sure to check [Caution](#Caution) section


## File saving

### How to use

1. add data to be saved via `add` method on plugin's singleton, each file params is passing as array in format: [Resource, String]

> [!TIP]
> See full params list at [Item params](#Item-params)

```gdscript
ThreadedSaver.add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
])
```

2. listen to needed signals

```gdscript
ThreadedSaver.saveCompleted.connect(_on_save_completed, CONNECT_ONE_SHOT)
```

3. start saving by calling `start` method
		
```gdscript
ThreadedSaver.start()
```

Also you may use inline saving and chain methods call:

> [!WARNING]
> Usage with `await` is undesirable, see [Caution](#Caution) section

```gdscript
await ThreadedSaver.add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
]).start().saveCompleted

# or

ThreadedSaver.add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
]).start().saveCompleted.connect(_on_save_completed, CONNECT_ONE_SHOT)

```


### Item params

The full params list per file is same as for godot's `ResourceSaver`:

```gdscript
[
  resource: Resource, 
  path: String | StringName = resource.resource_path,
  flags: BitField[SaverFlags] = 0
]
```


### Signals

```gdscript
# is emitted after method `start` been called
signal saveStarted(totalResources: int)

# is emitted per saved file (doesn't include access verification! see "Constructor params" section)
signal saveProgress(completedCount: int, totalResources: int, savedPath: String)

# is emitted when all files been saved (including access verification)
signal saveCompleted(savedPaths: Array[String])

# is emitted per saving err
signal saveError(path: String, errorCode: Error)

# is emitted when all the job is finished and prev threads and data are cleared (see `General` section for more details)
signal becameIdle()
```


### `start` method params


```gdscript
ThreadedSaver.start(
  verifyFilesAccess: bool = false, 
  threadsAmount: int = OS.get_processor_count() - 1
)
```

`verifyFilesAccess` - ensures to emit `saveCompleted` signal after saved files become accessible, useful when you need to change them right after saving but takes more time to process (depending on users system).

`threadsAmount` - how many threads will be used to process saving. You may pass your amount to save resources for additional parallel tasks (the amount will be cut to resources amount).


## File loading

### How to use`

1. add paths to be loaded and keys for them via `add` method on plugin's singleton, each file params is passing as array in format: Array[String, String]
   
> [!TIP]  
> - `STRING_NAME` type is also supported
> - the key - is a name to access the loaded resource (if you path an empty string - the resource path will be used as a key)
> - see full params list at [Item params](#Item-params-1)

```gdscript
ThreadedLoader.add([
  [<your key for resource>, <your path to load>],
  [<your key for resource>, <your path to load>],
  ...
])
```

1. listen to needed signals
   
```gdscript
ThreadedLoader.loadCompleted.connect(_on_load_completed, CONNECT_ONE_SHOT)
```

3. start loading by calling `start` method 	
   
```gdscript
ThreadedLoader.start()
```

Also you may use inline loading and chain methods call:

> [!WARNING]
> Usage with `await` is undesirable, see [Caution](#Caution) section

```gdscript
await ThreadedLoader.add([
  [<your key for resource>, <your path to load>],
  [<your key for resource>, <your path to load>],
  ...
]).start().loadCompleted

# or

ThreadedLoader.add([
  [<your key for resource>, <your path to load>],
  [<your key for resource>, <your path to load>],
  ...
]).start().loadCompleted.connect(_on_load_completed, CONNECT_ONE_SHOT)

```


### Item params

The full params list per file is same as for godot's `ResourceLoader`:

```gdscript
[
  key: String | StringName,
  path: String | StringName, 
  type_hint: String = "", 
  cache_mode: CacheMode = 1
]
```


### Signals

```gdscript
# is emitted after method `start` been called
signal loadStarted(totalResources: int)

# is emitted per loaded file
signal loadProgress(completedCount: int, totalResources: int, resource: Resource, resource_key: String)

# is emitted when all files been loaded
signal loadCompleted(loadedFiles: Dictionary)

# is emitted per loading err
signal loadError(path: String)

# is emitted when all the job is finished and prev threads and data are cleared (see `General` section for more details)
signal becameIdle()
```


### `start` method params

```gdscript
ThreadedLoader.start(
  threadsAmount: int = OS.get_processor_count() - 1
)
```
`threadsAmount` - how many threads will be used to process loading. You may pass your amount to save resources for additional parallel tasks (the amount will be cut to resources amount).


### Accessing loaded resources

`ThreadedLoader` provides you with `resource` itself and its `key` and `Dictionary[key: resource]` in `loadCompleted`

```gdscript
func start_load() -> void:
  ThreadedLoader.loadCompleted.connect(_on_load_completed, CONNECT_ONE_SHOT)
  ThreadedLoader.add([
    ["img", [res://1.jpg],
    ["scene", [res://2.tscn],
  ])

func _on_load_completed(loadedFiles: Dictionary) -> void:
  loadedFiles.img   # accessing loaded resource from "res://1.jpg"
  loadedFiles.scene # accessing loaded resource from "res://2.tscn"
```

or you may iterate the `loadedFiles` dictionary in loop. 


## General

1. You can globally silence all warnings as shown below:

```gdscript
ThreadedSaver.ignoreWarnings = true
ThreadedLoader.ignoreWarnings = true
```

2. `ThreadedSaver` batches the passed resources to save, so if you simultaneously call saving for the same path - only the last one (newest) will be processed. This will gain you a bit of performance, depending on saving frequency and file sizes by cutting the redundant work.

3. Both `ThreadedSaver` and `ThreadedLoader` has `is_idle` to get is it in idle state (doing nothing right now) and `get_current_threads_amount` to get currently used threads amount (will be 0 if in idle state)

4. In both `ThreadedSaver` and `ThreadedLoader` when the all job is done - cleaning starts and the threads are freed. At this moment all your new `start` calls will be delayed till cleaning finished and the `becameIdle` signal will be emitted. 
   
5. The `threadsAmount` param for `start` method in both `ThreadedSaver` and `ThreadedLoader` will automatically shrink to processed resources amount and won't change till reaches idle state. It never automatically grows.

```gdscript
ThreadedLoader.add([
  ["shuriken", "res://shuriken.jpg"],
  ["board", "res://board.jpg"],
]).start(5) # will be cut to 2 threads

...

ThreadedLoader.add([
  ["shuriken", "res://shuriken.jpg"],
  ["board", "res://board.jpg"],
]).start(1) # will be used 1 thread
```


### Caution

1. Batch `start` calls for save / load operations with `add` method instead of saving / loading each file separately (less `start` calls < performance)

```gdscript
# ---- bad

ThreadedLoader.add([["shuriken", "res://shuriken.jpg"]]).start()
...
await ThreadedLoader.becameIdle
ThreadedLoader.add([["board", "res://board.jpg"]]).start()
...

# ---- good

ThreadedLoader.add([
  ["shuriken", "res://shuriken.jpg"],
  ["board", "res://board.jpg"],
]).start()
...

```

2. Prefer explicit signal connections instead of `await` to avoid possible issues with godot (more info in #4)
 
3. If you will use ThreadedLoader with `await` to load file that makes the same inside - the inner `await` will never resolve:

```gdscript
# ---- file: main.gd


func _loadSubResource() -> void:
  await ThreadedLoader.add[["cll", "cll.gd"]].start().loadCompleted


# ---- file: cll.gd


var cll: Array[Resource] = [
  # never resolve!
  await ThreadedLoader.add[["t1", "texture1.png"]].start().loadCompleted,
  await ThreadedLoader.add[["t2", "texture2.png"]].start().loadCompleted,
  ...
]

```

All you need to do in this case - use for either outer or inner loaders (or both) explicit connection to the signal instead of `await`.

5. By default both `ThreadedLoader` and `ThreadedSaver` uses `OS.get_processor_count() - 1` amount of threads if you don't pass `threadsAmount` param, leaving 1 thread free. This is done on purpose to protect your main thread from freezes, but if your project won't do any hard work while you process resource save / load (like just showing the loading screen) - you may use all the threads and make this operations a bit faster, like in code example below. But it's not recommended as default behavior and better do some tests to confirm it behave as needed.

```gdscript
# using all the threads amount for resource load
ThreadedLoader.start(OS.get_processor_count())
```

6. Don't use "small deploy with network file system" for remote deploy, it will randomly cause resource loading errs. If you willing so or have to use it - to avoid the errs you will need to re-launch the project (maybe few time in a row).
  
7. The `start` params are ignored if been called when save / load was already in progress and the initial params will be used:

```gdscript
# start saving without `verifyFilesAccess`
ThreadedSaver.add([
  [res1, path1],
  [res2, path2],
  [res3, path3],
]).start(false, 3)

# start saving with `verifyFilesAccess`
ThreadedSaver.add([
  [res4, path4],
]).start(true) # if prev save is in progress at this point - this param will be ignored and file access for res4 won't be verified

```

If you need the new `start` params to be used - check saver / loader is idle via `is_idle` method and wait till it finish all current work, with the `becameIdle` signal. 
