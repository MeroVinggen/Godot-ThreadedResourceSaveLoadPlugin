<p align="center">
  <img src="./icon.svg" height="100" alt="Godot-ProjectileOnCurve2DPlugin Icon"/>
</p>

<h1 align="center">
  Godot ThreadedResourceSaveLoad Plugin
</h1>

<p align="center">
  <img src="./demo record.webp" height="350" alt="demo record"/>
</p>


## About

This plugin allows you to save/load resources <b>fast</b> in the background using threads, preventing the main thread freezes and handle the save/load operations using signals.

> This is not the final solution for save/load processing in your project, but a wrapper for the native ResourceSaver and ResourceLoader, allowing them to be used in parallel. You may use it directly or build your save/load managers(modules) around it to suit your needs.


## Features

- Adjusting threads amount to use per task
- progress(files amount)/errors/start/complete signals 
- optional files access verification after save
  

## Requirements 

- Godot 4.0 or higher


## Installation

- Open the `AssetLib` tab in Godot with your project open.
- Search for "ThreadedResourceSaveLoad Plugin" and install the plugin by Mero.
- Open Project -> Project Settings -> Plugins Tab and enable the plugin "ThreadedResourceSaveLoad".
- Done!


## Usage

> Make sure to check [Caution](#Caution) section.


## File saving

### How to use

1. create an instance

```
var saver: ThreadedResourceSaver = ThreadedResourceSaver.new()
```

2. add data to be saved via `add` method, each file params is passing as array in format: [Resource, String]]
> See full params list at [Item params](#Item-params)
```
saver.add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
])
```

3. listen to needed signals
```
saver.saveCompleted.connect(_onSaveCompleted, CONNECT_ONE_SHOT)
```

4. start saving by calling `start` method 	
```
saver.start()
```

Also you may use saving inline without saving ThreadedResourceSaver instance to a variable:

```
await ThreadedResourceSaver.new().add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
]).start().saveCompleted

# or

ThreadedResourceSaver.new().add([
  [<your resource>, <your path to save>],
  [<your resource>, <your path to save>],
  ...
]).start().saveCompleted.connect(_onSaveCompleted, CONNECT_ONE_SHOT)

```


### Item params

The full params list per file is same as for godot's `ResourceSaver`:
```
[
  resource: Resource, 
  path: String = "", 
  flags: BitField[SaverFlags] = 0
]
```


### Signals

```
# is emitted after method `start` been called
signal saveStarted(totalResources: int)

# is emitted per saved file (doesn't include access verification! see "Constructor params" section)
signal saveProgress(completedCount: int, totalResources: int)

# is emitted when all files been saved (including access verification)
signal saveCompleted(savedPaths: Array[String])

# is emitted per saving err
signal saveError(path: String, errorCode: Error)
```


### Constructor params


```
ThreadedResourceSaver.new(
  verifyFilesAccess: bool = false, 
  threadsAmount: int = OS.get_processor_count() - 1
)
```

`verifyFilesAccess` - ensures to emit `saveCompleted` signal after saved files become accessible, useful when you need to change them right after saving but takes more time to process (depending on users system).

`threadsAmount` - how many threads will be used to process saving. You may pass your amount to save resources for additional parallel tasks.


## File loading

### How to use

1. create an instance
```
var loader: ThreadedResourceLoader = ThreadedResourceLoader.new()
```

2. add paths to be loaded via `add` method, each file params is passing as array in format: Array[String]
> See full params list at [Item params](#Item-params-1)
```
loader.add([
  [<your path to load>],
  [<your path to load>],
  ...
])
```

3. listen to needed signals
```
loader.loadCompleted.connect(_onLoadCompleted, CONNECT_ONE_SHOT)
```

4. start loading by calling `start` method 	
```
loader.start()
```

Also you may use loading inline without saving ThreadedResourceLoader instance to a variable:

```
await ThreadedResourceLoader.new().add([
  [<your path to load>],
  [<your path to load>],
  ...
]).start().loadCompleted

# or

ThreadedResourceLoader.new().add([
  [<your path to load>],
  [<your path to load>],
  ...
]).start().loadCompleted.connect(_onLoadCompleted, CONNECT_ONE_SHOT)

```


### Item params

The full params list per file is same as for godot's `ResourceLoader`:
```
[
  path: String, 
  type_hint: String = "", 
  cache_mode: CacheMode = 1
]
```


### Signals

```
# is emitted after method `start` been called
signal loadStarted(totalResources: int)

# is emitted per loaded file
signal loadProgress(completedCount: int, totalResources: int)

# is emitted when all files been loaded
signal loadCompleted(loadedFiles: Array[Resource])

# is emitted per loading err
signal loadError(path: String)
```


### Constructor params


```
ThreadedResourceLoader.new(
  threadsAmount: int = OS.get_processor_count() - 1
)
```
`threadsAmount` - how many threads will be used to process loading. You may pass your amount to save resources for additional parallel tasks.


### Global config

You can silence all warnings as shown below:
```
ThreadedResourceSaver.ignoreWarnings = true
ThreadedResourceLoader.ignoreWarnings = true
```


### Caution

1. Make instance per task to perform, do not re-use them, this may cause unpredictable behavior.
 
2. If you will use ThreadedResourceLoader with await to load file that makes the same inside - inner await will never resolve:

```
# ---- file: main.gd


func _loadSubResource() -> void:
  await ThreadedResourceLoader.new().add[["cll.gd"]].start().loadCompleted


# ---- file: cll.gd


var cll: Array[Resource] = [
  # never resolve
  await ThreadedResourceLoader.new().add[["texture1.png"]].start().loadCompleted,
  await ThreadedResourceLoader.new().add[["texture2.png"]].start().loadCompleted,
  ...
]

```

All you need to do in this case - use for either outer or inner loaders (or both) connection to the signal instead of `await`.

3. By default both ThreadedResourceLoader and ThreadedResourceSaver uses `OS.get_processor_count() - 1` amount of threads if you don't pass `threadsAmount` param, leaving 1 thread free. This is done on purpose to protect your main thread from freezes, but if your project won't do any hard work while you process resource save/load(like just showing loading screen) - you may use all threads and make this operations a bit faster, like in code example below. But it's not recommended as default behavior and better do some tests to confirm it behave as needed.

```
# using all threads amount for resource load
ThreadedResourceLoader.new(OS.get_processor_count())...
```
4. Avoid creation many instances for simultaneously usage, as each instance will create it own threads and you easily will spawn more threads that system actually has, causing the main thread freezes. <b>Unless you are processing the used threads amount at the same time</b> <i>or you just know what you are doing</i>.

```
# --- bad

for resource in cll:
  ThreadedResourceLoader.new().add[[<path>]].start()


# --- good

var loader: ThreadedResourceLoader = ThreadedResourceLoader.new()

for resource in cll:
  loader.add[[<path>]]

loader.start()

```

5. Don't use "small deploy with network file system" for remote deploy, it will randomly cause resource loading errs. If you willing so or have to use it - to avoid the errs you will need to re-launch the project (maybe few time in a row).
