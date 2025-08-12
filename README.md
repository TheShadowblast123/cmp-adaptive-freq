# cmp-adaptive-freq
a neovim completion source based on user word frequency over on a per project basis.

## ⇁ Install
- [neovim](https://github.com/neovim/neovim) 0.8.0+ required 
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) required
- [using lazy nvim](https://github.com/folke/lazy.nvim)
```lua
```
## ⇁ Configuration
### ⇁ Default:
``` lua
local default_config = {
	max_items = 5,
	case_sensitive = false,
}
```
- max_items => the maximum amount of suggested results
- case_sensitive => NOT IMPLEMENTED, will upper case first letter if the first letter is already uppercased.
