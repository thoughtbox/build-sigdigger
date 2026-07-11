# what

This build script builds https://github.com/BatchDrake/SigDigger on Debian/Trixie.

# how

```bash
❯ ./build-sigdigger.sh 

Configuration
-------------
Install prefix : /home/tor/.local/sigdigger
Working tree   : /home/tor/programming/build-sigdigger/sigdigger-build
Build type     : Release
Parallel jobs  : 4
Update sources : no
Clean builds   : no
Create launcher: yes
Verbose output : no

Projects
--------
  1. sigutils
  2. suscan
  3. SuWidgets
  4. SigDigger

Continue? [Y/n]
[INFO] Cloning sigutils
...
...
strip /home/tor/.local/sigdigger/bin/SigDigger
make: Leaving directory '/home/tor/programming/build-sigdigger/sigdigger-build/SigDigger/build-v3'
[ OK ] SigDigger installed
[ OK ] Created /home/tor/.local/sigdigger/bin/sigdigger

[ OK ] Installation completed in 3m 19s

Installed under:
  /home/tor/.local/sigdigger

Run SigDigger:
  /home/tor/.local/sigdigger/bin/sigdigger

To make the installed commands available in future shells, add this line to
your shell profile:

  export PATH="/home/tor/.local/sigdigger/bin:$PATH"

The launcher sets the required library path automatically. Other programs
using these installed libraries may also need:

  export LD_LIBRARY_PATH="/home/tor/.local/sigdigger/lib:/home/tor/.local/sigdigger/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

build-sigdigger on  main ? took 3m19s 
```

# note 

It works for me; but please see suscan-notes.txt; I had to add an #include to two files.

# licence

MIT
