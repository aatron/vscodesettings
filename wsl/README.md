# WSL Set-up

## Settings

### Terminal

* WSL Color scheme - Dark+
* [herdr](https://herdr.dev/)

### Scripts folder

```
mkdir -p ~/tools/scripts
echo 'export PATH="$HOME/tools/scripts:$PATH"' >> ~/.bashrc
```

### Micro text editor

```
sudo apt update
sudo apt install micro
sudo apt install xclip
```

#### Micro settings

* Copy/paste might need some configuration
    * Smoke test:
        * Smoke test copy/paste list between Windows and: 
            * WSL bash
            * Micro
            * Herdr bash
            * Herdr micro
        * If any fails, likely need to set `~/.bashrc` to replace the display line with `export DISPLAY=:0`
    * This setting might be needed
        * In micro, press `Ctrl + e` --> `set clipboard external`

