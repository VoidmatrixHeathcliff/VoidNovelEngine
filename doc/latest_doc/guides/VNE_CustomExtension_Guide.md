# VoidNovelEngine 自定义节点、自定义场景与插件系统说明

> [!CAUTION]
>
> **适用版本：0.1.0-dev.3**
>
> 本文档介绍 **自定义节点**、**自定义引脚**、**自定义场景** 与 **插件系统**。

## 自定义扩展是什么

**自定义扩展** 用来补充内置节点无法覆盖的功能。普通剧情、演出、音频、界面和存档逻辑，建议优先使用引擎内置节点、`.vns` 文本剧本、样式设计视图和界面设计视图完成。

当项目需要接入更特殊的逻辑时，可以根据需求选择不同的扩展方式：

| 类型 | 适合场景 |
| :--- | :--- |
| **自定义节点** | 在流程图中新增一个可拖拽、可连线、可执行的节点。 |
| **自定义引脚** | 新增一种数据类型，或为某类数据提供专门的编辑、校验和保存方式。 |
| **自定义场景** | 临时接管一段独立运行逻辑，例如小游戏、战斗、复杂演出或特殊交互界面。 |
| **插件系统** | 把一组独立功能打包成目录，通过 `manifest.json` 自动注册为流程节点。 |

---

## 推荐选择方式

如果只是给流程图补一个动作，优先写 **自定义节点**。

如果需要一种内置引脚没有覆盖的数据类型，再写 **自定义引脚**。

如果需要独立的 `update / render` 循环，并且运行期间要临时接管输入和画面，可以写 **自定义场景**。

如果希望把节点、入口场景和私有资源一起打包，并让引擎自动扫描注册，可以使用 **插件系统**。

> [!NOTE]
>
> 自定义扩展属于开发者功能。扩展完成后，建议单独建立一个测试流程图，检查进入、退出、异常日志、存档读档、资源加载和发布包表现。

---

## 自定义节点

模板位置：

```text
application/node/custom/_自定义节点模板.lua
```

### 创建方式

1. 复制模板文件。
2. 把文件名改成不以下划线开头的 `.lua` 文件。
3. 修改 `type_id`，并保证在当前项目中唯一。
4. 修改节点标题、图标、分类、引脚和执行逻辑。
5. 重启编辑器后，在流程图右键菜单中使用。

> [!NOTE]
>
> 普通资源热重载不会重新加载 `application/node/custom` 与 `application/pin/custom` 中的定义脚本。新增或修改自定义节点、自定义引脚后，建议重启编辑器。

### 节点定义常用字段

| 字段或方法 | 说明 |
| :--- | :--- |
| `type_id` | 节点唯一标识，不能和内置节点或其他自定义节点重复。 |
| `title / name` | 节点在编辑器中显示的名称。 |
| `icon_id` | 节点图标，例如 `puzzle-fill`、`game-2-fill`。 |
| `color` | 节点头部颜色，通常使用 `ColorHelper` 中的预设颜色。 |
| `category` | 节点在右键菜单中的分类。 |
| `category_order / order` | 控制分类和节点的排序。 |
| `menu_visible` | 是否显示在右键创建菜单中。 |
| `keywords` | 搜索节点时可匹配的关键词。 |
| `builder:add_input` | 添加输入引脚。 |
| `builder:add_output` | 添加输出引脚。 |
| `on_execute` | 节点被执行时调用。 |
| `on_execute_update` | 节点需要跨帧等待时调用。 |
| `query_menu_id / on_show_menu` | 可选的节点右键菜单。 |

> [!WARNING]
>
> 节点字段使用 `icon_id`，不是 `icon`。`icon` 是运行时节点实例内部使用的图标对象，普通自定义节点定义中不要直接填写。

### 运行时读写引脚

自定义节点读取输入、写入输出时，建议使用模板中的 `NodeRuntimeHelper`：

```lua
node.on_execute = function(self, scene, entry_pin)
    local input_text = NodeRuntimeHelper.check_string(self, "input_text")
    NodeRuntimeHelper.set_output(self, "output_text", string.format("节点收到：%s", tostring(input_text)))
    NodeRuntimeHelper.execute_next_node(self, "out")
end
```

常用方法如下：

| 方法 | 用途 |
| :--- | :--- |
| `NodeRuntimeHelper.check_input(self, key, options)` | 按引脚 key 读取并校验输入值。 |
| `NodeRuntimeHelper.check_string / check_int / check_bool` | 读取常见类型输入值。 |
| `NodeRuntimeHelper.check_resource(self, key, asset_type)` | 读取纹理、音频、视频、字体、着色器等资源引用。 |
| `NodeRuntimeHelper.set_output(self, key, value)` | 写入输出引脚值。 |
| `NodeRuntimeHelper.execute_next_node(self, key)` | 从指定流程输出继续执行。 |
| `NodeRuntimeHelper.abort(self, message)` | 中止当前节点并输出运行时错误。 |

> [!NOTE]
>
> 新节点请尽量为每个引脚声明稳定的 `key`。后续保存、读取、文本剧本命令和插件输出绑定都会依赖这些 key。

---

## 自定义引脚

模板位置：

```text
application/pin/custom/_自定义引脚模板.lua
```

自定义引脚适合处理以下情况：

* 需要一种内置类型没有覆盖的数据。
* 需要专门的编辑器输入控件。
* 需要在连线时做更明确的数据类型限制。
* 需要自定义保存和读取格式。

### 引脚定义常用字段

| 字段或方法 | 说明 |
| :--- | :--- |
| `type_id` | 引脚类型唯一标识。 |
| `display_name / name` | 引脚类型在编辑器中显示的名称。 |
| `icon_type` | 引脚形状，例如圆形或菱形。 |
| `color` | 引脚颜色。 |
| `default_name` | 新建引脚时的默认显示名。 |
| `runtime.validate` | 运行前校验数据是否合法。 |
| `can_accept` | 可选的自定义连线兼容规则。 |
| `_on_tick_widgets` | 在节点上绘制引脚编辑控件。 |
| `on_load / on_save` | 控制引脚数据如何读取和保存。 |
| `set_val / get_val` | 设置和读取当前值。 |

> [!WARNING]
>
> 引脚 `type_id` 会进入流程文件。确定后不要随意改名，否则旧流程文件中的对应引脚可能无法正常恢复。

---

## 自定义场景

模板位置：

```text
application/scene/_自定义场景模板.lua
```

自定义场景适合处理比单个节点更完整的一段运行逻辑，例如：

* 战斗或小游戏。
* 需要独立 `update / render` 循环的交互。
* 复杂过场演出。
* 临时接管输入和画面渲染的特殊流程。

### 创建方式

1. 复制模板文件。
2. 把文件名改成不以下划线开头的 `.lua` 文件，例如 `custom_battle.lua`。
3. 在模板中实现进入、更新、渲染和退出逻辑。
4. 在流程图中使用 **切换到自定义场景** 节点。
5. 在节点里填写 Lua require 路径。

例如文件为：

```text
application/scene/custom_battle.lua
```

节点中填写：

```text
application.scene.custom_battle
```

### 场景核心方法

| 方法 | 调用时机 |
| :--- | :--- |
| `on_enter` | 进入场景时调用。 |
| `on_update(delta)` | 每帧更新逻辑。 |
| `on_render()` | 每帧绘制画面。 |
| `on_exit` | 离开场景时调用。 |
| `on_destroy` | 场景销毁时调用。 |
| `_finish_scene()` | 调用后回到后续流程。 |

> [!NOTE]
>
> 如果需要使用 `add_object`、`open_ui`、运行时输入、存档对象等 `Scene` 基类能力，请保留模板中 `on_update`、`on_render`、`on_destroy` 的父类调用。

---

## 插件系统

**插件系统** 适合把一组独立功能打包成一个目录，然后放到项目根目录的 `plugins/` 下。

和普通自定义节点不同，插件会由引擎扫描 `manifest.json`，并自动注册成一个流程节点。这个节点执行时会加载插件自己的入口场景，进入一段独立逻辑；插件结束后，再回到后续流程。

插件适合处理这些情况：

* 一段可复用的小游戏或战斗系统。
* 需要独立资源目录的特殊演出。
* 需要把输入参数、输出结果和运行场景一起打包的扩展。
* 需要在编辑器中快速启用或卸载的一组 Lua 逻辑。

> [!NOTE]
>
> 编辑器启动时会扫描 `plugins/`。编辑器运行中如果监听到插件目录变化，也会尝试重新扫描插件包。自定义 node/pin 不走这条热重载链路。

> [!WARNING]
>
> 当前发布流程会自动复制 `application/node`、`application/pin`、`application/scene` 等目录。若项目依赖根目录下的 `plugins/`，发布前请确认发布目录中也包含对应插件目录，否则发布版运行时无法扫描到插件节点。

### 推荐目录结构

```text
plugins/
  game_demo/
    manifest.json
    scene.lua
    node_def.lua        # 可选
    resources/
      texture/
      audio/
```

其中 `manifest.json` 和 `scene.lua` 是核心文件。`resources/` 用来放插件私有资源。`node_def.lua` 只在需要完全自定义节点显示或构建逻辑时使用。

---

## 插件 manifest.json

`manifest.json` 描述插件如何显示、如何注册节点、入口场景在哪里，以及节点需要哪些输入输出。

常用字段如下：

| 字段 | 说明 |
| :--- | :--- |
| `kind` | 可省略；填写时必须为 `"plugin"`。 |
| `api_version` | 当前写 `1`。 |
| `id` | 插件唯一标识。只能包含字母、数字、下划线、中划线和点号。 |
| `display_name` | 插件节点在编辑器里显示的名称。 |
| `version / author / description` | 版本、作者和说明文字。 |
| `icon_id` | 节点图标，例如 `game-2-fill`。 |
| `color` | 节点颜色，格式为 `[r, g, b, a]`。 |
| `category` | 节点所在分类，默认是 `插件场景`。 |
| `category_order` | 插件分类在右键菜单中的排序，默认是 `10`。 |
| `category_default_open` | 插件分类是否默认展开，默认是 `true`。 |
| `order` | 节点在分类中的排序，默认是 `100`。 |
| `menu_visible` | 是否显示在右键创建菜单中，默认是 `true`。 |
| `entry_point` | 插件入口 Lua 文件，默认是 `scene.lua`。 |
| `resource_root` | 插件私有资源目录，默认是 `resources`。 |
| `resources` | 私有资源别名表。 |
| `node_type_id` | 自动注册出的节点类型；可省略，默认按插件 id 生成。 |
| `input_pins` | 插件节点输入引脚列表；可省略，默认有一个 `flow` 输入。 |
| `output_pins` | 插件节点输出引脚列表；可省略，默认有一个 `flow` 输出。 |
| `supports_save` | 是否声明支持运行时存档。 |
| `reload_modules` | 重新加载插件时是否清理插件包内 Lua 模块缓存，默认开启。 |

最小结构示例：

```json
{
    "kind": "plugin",
    "api_version": 1,
    "id": "game_demo",
    "display_name": "小游戏",
    "entry_point": "scene.lua",
    "resource_root": "resources",
    "node_type_id": "plug_game_demo",
    "input_pins": [
        {"type_id": "flow", "key": "in"}
    ],
    "output_pins": [
        {"type_id": "flow", "key": "out"}
    ]
}
```

> [!WARNING]
>
> `id` 和 `node_type_id` 会进入流程文件。插件发布后不要随意改名，否则旧流程里已经放置的插件节点可能变成不可用节点。

### id 与路径限制

插件 `id` 只能包含字母、数字、下划线、中划线和点号，并且不要使用点号路径语义，例如以点开头、以点结尾或包含连续点号。

`entry_point`、`resource_root` 和 `resources` 中的资源路径都必须是插件目录内的相对路径，不能写绝对路径，也不能使用 `..` 跳出插件目录。

---

## 插件引脚

`input_pins` 和 `output_pins` 中的每一项都是一个引脚描述。

常用字段如下：

| 字段 | 说明 |
| :--- | :--- |
| `type_id` | 引脚类型，例如 `flow`、`int`、`bool`、`texture`、`audio`。 |
| `key` | 在 `scene.lua` 中读取参数或写回输出时使用的键。 |
| `name` | 编辑器里显示的引脚名称。 |
| `default` | 输入没有连接或读取失败时使用的默认值。 |
| `options` | 传给引脚编辑器的选项，例如 `{"can_edit": false}`。 |

插件节点至少需要：

* 一个 `flow` 输入引脚。
* 一个 `flow` 输出引脚。

普通输入引脚会写入 `scene.lua` 构造参数。例如：

```json
{"type_id": "int", "key": "difficulty", "name": "难度", "default": 1}
```

在 `scene.lua` 中读取：

```lua
self.difficulty = tonumber(args.difficulty) or 1
```

资源类输入引脚会额外保留资源引用，避免插件运行过程中资源被提前释放。当前会做保活处理的类型包括：

```text
texture / audio / video / font / shader
```

> [!NOTE]
>
> 插件引脚使用的 `type_id` 必须已经注册。也就是说，如果插件节点使用了自定义引脚，需要先把对应引脚定义放到 `application/pin/custom` 中，并重启编辑器。

---

## 插件 scene.lua

`scene.lua` 必须返回一个带 `new()` 的 Scene 类。推荐继承引擎的基础 `Scene`，和普通自定义场景保持一致。

插件场景会收到一个 `args` 表：

| 字段 | 说明 |
| :--- | :--- |
| 普通输入 `key` | 来自 `manifest.json` 中非 `flow` 输入引脚的值。 |
| `manifest` | 当前插件的 manifest。 |
| `host_scene` | 启动插件时所在的宿主场景。 |
| `node` | 当前插件节点对象。 |
| `resources` | 插件私有资源上下文。 |
| `resource_inputs` | 资源类输入引脚的引用信息。 |

常用结构如下：

```lua
local Class = require("application.framework.class")
local Scene = require("application.framework.scene")

local MyPluginScene = Class.define("MyPluginScene", Scene)

function MyPluginScene:ctor(args)
    Class.call_super(MyPluginScene, self, "ctor")
    self.difficulty = tonumber(args.difficulty) or 1
    self.resources = args.resources
    self._output_values =
    {
        score = 0,
        completed = false,
    }
end

function MyPluginScene:on_update(delta)
    Scene.on_update(self, delta)
end

function MyPluginScene:_finish()
    self._output_values.score = 100
    self._output_values.completed = true
    if self.complete then
        self:complete("out")
    end
end

return MyPluginScene
```

插件结束时调用 `self:complete()` 或模板中的 `self:_execute_next_node()`，引擎会：

1. 销毁插件场景。
2. 写回 `self._output_values` 中和输出引脚 `key` 对应的值。
3. 执行后续流程。

> [!NOTE]
>
> `complete()` 可以传入流程输出 key，例如 `self:complete("success")`。不传时会走默认输出。

> [!WARNING]
>
> 插件输出值在结束阶段从 `self._output_values` 中读取。不要在 `on_exit` 或 `on_destroy` 中把 `_output_values` 清空，否则后续节点可能读不到插件输出。

插件场景的 `on_enter`、`on_update` 和 `on_render` 都会被运行时做错误保护。发生异常时，引擎会中止当前插件节点，并把错误写入运行日志。

---

## 插件私有资源

插件私有资源放在 `resource_root` 指定的目录中，默认是：

```text
resources/
```

`manifest.json` 可以为资源声明别名：

```json
"resources": {
    "background": "texture/background.png",
    "music": "audio/bgm.ogg",
    "eat_sound": "audio/eat.wav"
}
```

上面的路径是相对 `resource_root` 的路径。如果 `resource_root` 使用默认值 `resources`，不要写成 `resources/texture/background.png`。

`scene.lua` 中通过 `args.resources` 读取：

| 方法 | 说明 |
| :--- | :--- |
| `resources:get_declared(name)` | 读取 manifest 中声明的资源相对路径。 |
| `resources:resolve_path(path, expected_type)` | 解析插件资源的真实路径。 |
| `resources:find_texture(path)` | 加载插件私有纹理。未传 path 时默认找 `background`。 |
| `resources:find_audio(path)` | 加载插件私有音频。未传 path 时默认找 `music`。 |
| `resources:dispose()` | 释放插件私有资源。通常由引擎自动调用。 |

支持的私有资源扩展名：

| 类型 | 扩展名 |
| :--- | :--- |
| `texture` | `.png`、`.jpg`、`.jpeg`、`.tif`、`.tiff`、`.webp`、`.avif` |
| `audio` | `.wav`、`.mp3`、`.ogg`、`.flac` |

> [!WARNING]
>
> 插件私有资源系统当前只提供纹理和音频的直接加载接口。视频、字体、着色器可以作为资源类输入引脚保活，但插件私有目录中没有对应的 `find_video`、`find_font` 或 `find_shader` 快捷方法。

---

## 插件存档

如果插件运行过程中允许玩家存档，需要在 `manifest.json` 中声明：

```json
"supports_save": true
```

并在 `scene.lua` 中实现这些方法：

| 方法 | 说明 |
| :--- | :--- |
| `can_save_now(context)` | 返回当前是否允许存档。 |
| `collect_plugin_state()` | 返回可写入存档的插件状态。 |
| `apply_plugin_state(state)` | 读档后恢复插件状态。 |

示例：

```lua
function MyPluginScene:can_save_now(context)
    return true
end

function MyPluginScene:collect_plugin_state()
    return
    {
        schema_version = 1,
        score = self.score,
        completed = self.completed,
    }
end

function MyPluginScene:apply_plugin_state(state)
    local snapshot = type(state) == "table" and state or {}
    self.score = tonumber(snapshot.score) or 0
    self.completed = snapshot.completed == true
    return true
end
```

> [!NOTE]
>
> 插件存档恢复采用重新执行插件节点的方式。读档时，引擎会重新创建插件场景，再调用 `apply_plugin_state(state)` 恢复插件自己的状态。

> [!CAUTION]
>
> 存档状态只保存普通 Lua 数据。不要把纹理、音频、场景对象、函数或运行时句柄写进 `collect_plugin_state()` 的返回值。

---

## 可选 node_def.lua

默认情况下，引擎会根据 `manifest.json` 自动生成插件节点。

如果需要更细的节点显示控制，可以在插件目录中增加：

```text
node_def.lua
```

该文件返回一个节点定义 table。引擎仍会使用 manifest 中的 `node_type_id`，并把 `plugin_manifest` 注入定义中。没有特殊需求时，不建议编写 `node_def.lua`，直接使用自动节点更稳定。

适合使用 `node_def.lua` 的情况：

* 需要覆盖节点标题、颜色、图标或分类。
* 需要自定义节点构建逻辑。
* 需要给节点增加特殊右键菜单。

> [!WARNING]
>
> 如果在 `node_def.lua` 中覆盖 `build`，需要自行保留插件执行逻辑。否则这个节点可能只会显示在流程图中，但不会启动插件场景。

> [!NOTE]
>
> 如果 `node_def.lua` 加载失败，引擎会记录 warning，并回退到 manifest 自动生成的节点定义。

---

## 发布前检查清单

1. `application/node/custom` 与 `application/pin/custom` 中的脚本文件名不以下划线开头。
2. 自定义节点、引脚、插件的 `type_id` 或 `node_type_id` 没有重复。
3. 插件 `manifest.json` 能被正常解析，入口 `scene.lua` 存在，并返回带 `new()` 的 Scene 类。
4. 插件输入和输出至少各有一个 `flow` 引脚。
5. 非 `flow` 输出值写入 `self._output_values`，并和输出引脚 `key` 对齐。
6. 私有资源都在插件 `resource_root` 下，不使用绝对路径和 `..`。
7. 声明 `supports_save` 后，补齐存档检查、状态收集和状态恢复方法。
8. 用测试流程检查进入插件、退出插件、输出值、异常日志和读档恢复。
9. 发布后检查发布目录中是否包含项目需要的自定义脚本和插件目录。