Forked workflow from EgoMoose's UI image asset uploads via [asphalt](https://github.com/jackTabsCode/asphalt). This will essentially do the same thing but allow you to upload KeyframeSequence .rbxm files as animations. Animation names on Roblox will be obfuscated, with the generated code giving you the original name mapped to the uploaded ID. 

This workflow expects only `.rbxm` files. You _can_ upload multiple at a time by exporting them as one Model. Note that the tooling will preserve KeyframeSequence names. 

### How to use

First copy and rename the `asphalt_template.toml` to `asphalt.toml`. Then in the new file update the user id and add an open cloud api key with asset write permissions.

If uploading images:
* Place the png's under the `assets` folder. Then run the lune script:
  ```Lua
  lune run upload
  ```
If uploading animations:
* Place .rbxm files under the `assets` folder, then run:
  ```Lua
    lune run animations
  ```
