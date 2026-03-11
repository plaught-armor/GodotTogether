# Godot Together
[Wiki](https://github.com/Wolfyxon/GodotTogether/wiki/) |
[Troubleshooting](https://github.com/Wolfyxon/GodotTogether/wiki/Troubleshooting)

An **experimental** plugin for real-time collaboration over the network for Godot Engine.

> [!WARNING]
> This plugin is **not ready for production use.**
> Many features are not yet implemented or are still being tested.
> You are also risking **breaking your project** so make sure to **make a backup**.
>
> See the [TODO list](https://github.com/wolfyxon/godotTogether/issues/1) to see the current progress.

> [!CAUTION]
> Never EVER join or host projects to people you don't trust.
> Your project can be very easily stolen and someone can remotely execute malicious code with tool scripts.

## Features
- Real-time node property syncing (add, delete, rename, reparent, reorder)
- 3D camera tracking with quaternion-based rotation (no gimbal lock)
- File syncing (add, modify, delete) with auto-reload for scenes
- Tool script detection warnings
- Password-protected sessions
- User approval system
- In-editor chat
- 2D/3D avatar markers

## Installation
First create a folder called `addons` in your project's directory.

### Getting the plugin

#### From releases (recommended)
1. Download the latest release zip from the [Releases](https://github.com/Wolfyxon/GodotTogether/releases) page.
2. Extract the zip into your project's root directory.

The structure should look like this:
```
yourProject
|_ addons
  |_ GodotTogether
    |_ src
      |_ scripts
      |_ img
      |_ scenes
```

#### With Git
Open the terminal in your `addons` folder, then run:
```
git clone https://github.com/Wolfyxon/GodotTogether.git
```

Then proceed to the [enabling section](#enabling).

#### Manual download

1. [Download the source code](https://github.com/Wolfyxon/GodotTogether/archive/refs/heads/main.zip) zip.
2. Extract the zip contents into your `addons` folder.
3. Rename `GodotTogether-main` to `GodotTogether`.

### Enabling
1. Click on **Project** on the top-left toolbar.
2. Go to **Project settings**
3. Go to the **plugins** tab
4. Enable **Godot Together**

## Contributing
Contributions are welcome! Please ensure your code is formatted with the [GDQuest GDScript formatter](https://github.com/GDQuest/GDScript-formatter) before submitting a PR.
